import copy
import json
import tempfile
import unittest
from pathlib import Path

from resqmesh_controller import PROTOCOL_EPOCH_ID, PROTOCOL_VERSION
from resqmesh_controller.config import (
    ConfigError,
    research_fingerprint,
    smoke_matches_config,
    validate_config,
)
from resqmesh_controller.controller import (
    BatchIncompleteError,
    ExperimentController,
    build_plan,
)
from resqmesh_controller.devices import NodeTransport


ROOT = Path(__file__).resolve().parents[3]


def physical_config() -> dict:
    value = json.loads(
        (ROOT / "tools" / "experiment_controller" / "config.example.json").read_text(
            encoding="utf-8"
        )
    )
    value["android_build_id"] = "0123456789ab"
    value["firmware_build_id"] = "0123456789ab"
    value["observation_window_seconds"] = 1
    value["quiet_period_seconds"] = 0
    value["trial_order"] = "blocked"
    return value


def event(
    node_id: str,
    session_id: str,
    trial_id: str | None,
    event_type: str,
    *,
    message_key: str = "100:200",
    hop: int | None = None,
    timestamp: int = 1000,
) -> dict:
    value = {
        "kind": "event",
        "node_id": node_id,
        "session_id": session_id,
        "trial_id": trial_id,
        "event_type": event_type,
        "message_key": message_key,
        "timestamp_ms": timestamp,
        "clock_sync_valid": True,
        "burst_id": f"{node_id}-{trial_id}-{event_type}",
        "packet_type": "sos",
    }
    if hop is not None:
        value["hop_in"] = hop
    return value


class FakeNode(NodeTransport):
    def __init__(self, item: dict, config: dict, provider) -> None:
        self.node_id = item["node_id"]
        self.role = item["role"]
        self.transport = item["transport"]
        self.config = config
        self.provider = provider
        self.commands: list[tuple[str, dict]] = []
        self.session_id = ""
        self.trial_id = ""
        self.mode = ""
        self.active = False
        self.expected_hop = 0
        self.hop_out = 0
        self.reported_build_id: str | None = None

    def command(self, name: str, arguments: dict) -> dict:
        self.commands.append((name, dict(arguments)))
        if name == "configure_session":
            self.session_id = arguments["session_id"]
            self.mode = arguments["mode"]
            self.role = arguments["role"]
            self.active = arguments["protocol_active"]
            self.expected_hop = arguments["expected_hop_in"]
            self.hop_out = arguments["hop_out"]
        elif name == "start_trial":
            self.trial_id = arguments["trial_id"]
        elif name == "reset_trial":
            self.trial_id = ""
        if name == "readiness":
            return {
                "ok": True,
                "command_id": arguments.get("command_id"),
                "epoch_id": PROTOCOL_EPOCH_ID,
                "epoch_valid": True,
                "clock_valid": True,
                "bluetooth": True,
                "permissions": {"scan": True, "advertise": True},
                "scanner": True,
                "advertising": False,
                "queue_size": 0,
                "packet_pending": False,
                "quiet_period_complete": True,
                "payload_length": 17,
                "manufacturer_id": 0xFFFF,
                "protocol_version": PROTOCOL_VERSION,
                "android_build_id": self.reported_build_id
                or self.config["android_build_id"],
                "firmware_build_id": self.reported_build_id
                or self.config["firmware_build_id"],
                "session_id": self.session_id or None,
                "trial_id": self.trial_id or None,
                "mode": self.mode or None,
                "role": self.role,
                "protocol_active": self.active,
                "gateway_enabled": False,
                "ack_enabled": False,
            }
        if name == "trigger_sos":
            return {
                "ok": True,
                "command_id": arguments.get("command_id"),
                "message_key": "100:200",
            }
        return {"ok": True, "command_id": arguments.get("command_id")}

    def host_clock_offset_ms(self) -> float:
        return 0.0

    def collect_events(self, session_id=None, trial_id=None) -> list[dict]:
        return self.provider(self, session_id, trial_id)


def standard_provider(outcome_by_attempt=None):
    outcomes = outcome_by_attempt or (lambda _attempt: "SUCCESS")

    def provide(node: FakeNode, session_id: str, trial_id: str) -> list[dict]:
        attempt = int(trial_id.rsplit("A", 1)[1])
        hypothesis = trial_id.split("-")[1]
        mode = trial_id.split("-")[0]
        outcome = outcomes(attempt)
        values: list[dict] = []
        if node.node_id == "android-source":
            values.append(event(node.node_id, session_id, trial_id, "SOURCE_FIRST_ADVERTISE_STARTED"))
        if node.node_id == "esp-r1a" and outcome == "INVALID":
            values.append(event(node.node_id, session_id, trial_id, "EXPERIMENT_CONFIG_VIOLATION"))
            values[-1]["reason"] = "SIMULATED_INVALID"
        if node.node_id == "esp-destination" and outcome == "SUCCESS":
            values.append(
                event(
                    node.node_id,
                    session_id,
                    trial_id,
                    "DESTINATION_FIRST_VALID_RECEIVE",
                    hop=int(hypothesis[1:]),
                    timestamp=1300,
                )
            )
        if node.node_id == "esp-r1b" and mode == "trickle" and hypothesis in {"H2", "H3"}:
            values.append(event(node.node_id, session_id, trial_id, "TRICKLE_CONSISTENT_HEARD"))
            values.append(event(node.node_id, session_id, trial_id, "TRICKLE_TX_SUPPRESSED"))
        return values

    return provide


def fake_nodes(config: dict, provider=None) -> list[FakeNode]:
    callback = provider or standard_provider()
    return [FakeNode(item, config, callback) for item in config["nodes"]]


class ControllerTest(unittest.TestCase):
    def test_placeholder_build_ids_are_rejected(self) -> None:
        value = physical_config()
        value["android_build_id"] = "unknown"
        value["firmware_build_id"] = "esp32c3-dev"
        with self.assertRaises(ConfigError) as raised:
            validate_config(value)
        self.assertIn("Git commit SHA", str(raised.exception))

    def test_matching_commit_build_ids_are_accepted_and_mismatch_is_rejected(self) -> None:
        value = physical_config()
        validate_config(value)
        value["firmware_build_id"] = "abcdef012345"
        with self.assertRaises(ConfigError) as raised:
            validate_config(value)
        self.assertIn("same commit", str(raised.exception))

    def test_readiness_rejects_device_with_different_build_id(self) -> None:
        value = physical_config()
        nodes = fake_nodes(value)
        nodes[0].reported_build_id = "abcdef012345"
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, nodes, Path(temporary), sleep=lambda _: None)
            with self.assertRaisesRegex(Exception, "build identity"):
                controller.readiness()

    def test_research_fingerprint_tracks_research_inputs_not_trial_target(self) -> None:
        value = physical_config()
        original = research_fingerprint(value)
        target_changed = copy.deepcopy(value)
        target_changed["valid_trials_per_condition"] = 99
        target_changed["max_attempts_per_condition"] = 120
        target_changed["trial_order"] = "randomized"
        self.assertEqual(original, research_fingerprint(target_changed))

        for mutation in ("build", "topology", "window"):
            changed = copy.deepcopy(value)
            if mutation == "build":
                changed["android_build_id"] = "abcdef012345"
                changed["firmware_build_id"] = "abcdef012345"
            elif mutation == "topology":
                changed["nodes"][1]["topology"]["H2"]["hop_out"] = 9
            else:
                changed["observation_window_seconds"] += 1
            self.assertNotEqual(original, research_fingerprint(changed), mutation)

        report = {"passed": True, "config_fingerprint": original}
        self.assertTrue(smoke_matches_config(report, value))
        self.assertFalse(smoke_matches_config(report, changed))

    def test_default_matrix_contains_90_trials(self) -> None:
        value = physical_config()
        self.assertEqual(90, len(build_plan(value)))
        randomized = value | {"trial_order": "randomized", "random_seed": 7}
        self.assertEqual(build_plan(randomized), build_plan(randomized))
        self.assertNotEqual(build_plan(value), build_plan(randomized))

    def test_five_esp32_template_and_topology_validate(self) -> None:
        value = physical_config()
        validate_config(value)
        self.assertEqual(5, sum(node["transport"] == "serial" for node in value["nodes"]))
        self.assertEqual(6, len(value["nodes"]))

    def test_config_rejects_duplicate_port_and_broken_chain(self) -> None:
        value = physical_config()
        value["nodes"][2]["port"] = value["nodes"][1]["port"]
        for index in (3, 4):
            value["nodes"][index]["topology"]["H3"] = {
                "role": "OBSERVER",
                "active": False,
            }
        with self.assertRaises(ConfigError) as raised:
            validate_config(value)
        self.assertIn("duplicate COM port", str(raised.exception))
        self.assertIn("relay chain", str(raised.exception))

    def test_old_or_unscoped_events_cannot_change_current_trial(self) -> None:
        value = physical_config()
        value["valid_trials_per_condition"] = 1

        def stale_provider(node: FakeNode, session_id: str, trial_id: str) -> list[dict]:
            values = []
            if node.node_id == "android-source":
                values.append(event(node.node_id, session_id, trial_id, "SOURCE_FIRST_ADVERTISE_STARTED"))
                values.append(event(node.node_id, session_id, None, "EXPERIMENT_CONFIG_VIOLATION"))
            if node.node_id == "esp-destination":
                values.append(event(node.node_id, session_id, "old-trial", "DESTINATION_FIRST_VALID_RECEIVE", hop=1))
                values.append(event(node.node_id, session_id, trial_id, "DESTINATION_FIRST_VALID_RECEIVE", message_key="other", hop=1))
            return values

        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, fake_nodes(value, stale_provider), Path(temporary), sleep=lambda _: None)
            result = controller.run_trial(build_plan(value)[0])
            self.assertEqual("FAILED_DELIVERY", result["result"])
            raw = list((Path(temporary) / "raw" / result["trial_id"]).rglob("*.jsonl"))
            text = "".join(path.read_text(encoding="utf-8") for path in raw)
            self.assertNotIn("old-trial", text)
            self.assertNotIn('"trial_id": null', text)

    def test_events_from_all_five_esp32_are_collected(self) -> None:
        value = physical_config()
        value["valid_trials_per_condition"] = 1

        def provider(node: FakeNode, session_id: str, trial_id: str) -> list[dict]:
            values = standard_provider()(node, session_id, trial_id)
            if node.transport == "serial":
                values.append(event(node.node_id, session_id, trial_id, "NODE_DIAGNOSTIC"))
            return values

        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, fake_nodes(value, provider), Path(temporary), sleep=lambda _: None)
            result = controller.run_trial(build_plan(value)[0])
            trial_dir = Path(temporary) / "raw" / result["trial_id"]
            for node_id in ("esp-r1a", "esp-r1b", "esp-r2a", "esp-r2b", "esp-destination"):
                self.assertIn("NODE_DIAGNOSTIC", (trial_dir / f"{node_id}.jsonl").read_text(encoding="utf-8"))

    def test_invalid_attempts_are_replaced_until_three_valid(self) -> None:
        value = physical_config()
        value["valid_trials_per_condition"] = 3
        value["max_attempts_per_condition"] = 5
        outcomes = lambda attempt: {1: "INVALID", 2: "SUCCESS", 3: "FAILED_DELIVERY"}.get(attempt, "SUCCESS")
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(
                value,
                fake_nodes(value, standard_provider(outcomes)),
                Path(temporary),
                sleep=lambda _: None,
            )
            controller.run()
            for row in controller.batch_summary()["conditions"]:
                self.assertEqual(3, row["valid"])
                self.assertEqual(1, row["invalid"])
                self.assertEqual(4, row["attempts"])
                self.assertEqual(2 / 3, row["success"] / row["valid"])

    def test_resume_does_not_trigger_terminal_attempts_again(self) -> None:
        value = physical_config()
        value["valid_trials_per_condition"] = 1
        value["max_attempts_per_condition"] = 1
        with tempfile.TemporaryDirectory() as temporary:
            nodes = fake_nodes(value)
            controller = ExperimentController(value, nodes, Path(temporary), sleep=lambda _: None)
            controller.run()
            trigger_count = sum(name == "trigger_sos" for node in nodes for name, _ in node.commands)
            resumed = ExperimentController(value, nodes, Path(temporary), sleep=lambda _: None)
            resumed.run()
            self.assertEqual(
                trigger_count,
                sum(name == "trigger_sos" for node in nodes for name, _ in node.commands),
            )

    def test_max_attempts_stops_with_non_complete_summary(self) -> None:
        value = physical_config()
        value["valid_trials_per_condition"] = 1
        value["max_attempts_per_condition"] = 2
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(
                value,
                fake_nodes(value, standard_provider(lambda _attempt: "INVALID")),
                Path(temporary),
                sleep=lambda _: None,
            )
            with self.assertRaises(BatchIncompleteError) as raised:
                controller.run()
            self.assertFalse(raised.exception.summary["complete"])
            self.assertTrue((Path(temporary) / "attempt_summary.csv").exists())

    def test_smoke_report_requires_all_six_conditions(self) -> None:
        value = physical_config()
        value["valid_trials_per_condition"] = 1
        value["max_attempts_per_condition"] = 1
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, fake_nodes(value), Path(temporary), sleep=lambda _: None)
            controller.run()
            report = controller.smoke_report()
            self.assertTrue(report["passed"])
            self.assertEqual(6, len(report["conditions"]))
            self.assertTrue((Path(temporary) / "smoke_report.csv").exists())

    def test_manifest_trial_record_contains_reconstruction_inputs(self) -> None:
        value = physical_config()
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, fake_nodes(value), Path(temporary), sleep=lambda _: None)
            result = controller.run_trial(build_plan(value)[0])
            self.assertEqual(controller.manifest["session_id"], result["session_id"])
            self.assertEqual("android-source", result["source_node_id"])
            self.assertEqual(["esp-destination"], result["destination_node_ids"])
            self.assertEqual(1000, result["observation_window_ms"])
            self.assertEqual(value["clock_tolerance_ms"], result["clock_tolerance_ms"])
            self.assertEqual("100:200", result["message_key"])


if __name__ == "__main__":
    unittest.main()
