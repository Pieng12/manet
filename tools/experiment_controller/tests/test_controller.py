import copy
import json
import tempfile
import time
import unittest
from unittest.mock import patch
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
    value["modes"] = ["trickle", "basic_flooding", "trickle_no_suppression"]
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
        self.reported_rx_burst_gap_ms: int | None = None
        self.reject_configure_while_stale = False
        self.source_started_at_ms = None

    def command(self, name: str, arguments: dict) -> dict:
        self.commands.append((name, dict(arguments)))
        if name == "configure_session":
            if self.reject_configure_while_stale and self.trial_id:
                return {
                    "ok": False,
                    "command_id": arguments.get("command_id"),
                    "error": "STALE_TRIAL_RUNNING",
                }
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
            self.source_started_at_ms = None
        if name in {"readiness", "get_status"}:
            return {
                "ok": True,
                "command_id": arguments.get("command_id"),
                "epoch_id": PROTOCOL_EPOCH_ID,
                "epoch_valid": True,
                "clock_valid": True,
                "bluetooth": True,
                "permissions": {"scan": True, "advertise": True},
                "scanner": True,
                "radio": {
                    "ready": True, "requested_mode": "coded", "configured_mode": "coded",
                    "primary_phy": "coded", "secondary_phy": "coded", "scan_phy": "coded",
                    "advertising_interval_units": 400,
                    "coding_selection_support": "unsupported", "s8_requirement_accepted": False,
                    "on_air_coding_verified": False,
                },
                "advertising": False,
                "queue_size": 0,
                "packet_pending": False,
                "quiet_period_complete": True,
                "payload_length": 17,
                "measurement_timing_version": 2,
                "method_design_version": 3,
                "suppression_enabled": self.mode == "trickle",
                "trickle_imin_ms": 8000, "trickle_imax_ms": 256000,
                "trickle_k": 1, "burst_duration_ms": 2000,
                "source_first_advertise_started_at_ms": self.source_started_at_ms,
                "source_first_advertise_message_key": "100:200" if self.source_started_at_ms else None,
                "manufacturer_id": 0xFFFF,
                "protocol_version": PROTOCOL_VERSION,
                "rx_burst_gap_ms": self.reported_rx_burst_gap_ms
                if self.reported_rx_burst_gap_ms is not None
                else self.config["rx_burst_gap_ms"],
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
            self.source_started_at_ms = time.time_ns() // 1_000_000
            return {
                "ok": True,
                "command_id": arguments.get("command_id"),
                "message_key": "100:200",
            }
        return {"ok": True, "command_id": arguments.get("command_id")}

    def host_clock_offset_ms(self) -> float:
        return 0.0

    def collect_events(self, session_id=None, trial_id=None) -> list[dict]:
        values = self.provider(self, session_id, trial_id)
        source = next((x for name, x in reversed(self.commands)
                       if name == "end_observation_window" and x.get("trial_id") == trial_id), {})
        base_timestamp = source.get("observation_ended_at_ms", time.time_ns() // 1_000_000) - int(self.config["observation_window_seconds"] * 1000)
        if self.source_started_at_ms is not None:
            base_timestamp = self.source_started_at_ms
        # Synthetic software fixture, not a measured experiment dataset.
        if self.node_id == 'android-source' and self.mode.startswith('trickle') and any(
                e.get('event_type') == 'SOURCE_FIRST_ADVERTISE_STARTED' for e in values):
            values.extend([
                event(self.node_id, session_id, trial_id, 'TRICKLE_INTERVAL_STARTED', timestamp=base_timestamp - 5000),
                event(self.node_id, session_id, trial_id, 'TRICKLE_TX_OPPORTUNITY', timestamp=base_timestamp),
            ])
            values[-2].update(interval_ms=8000, interval_started_at_monotonic_ms=10000,
                              transmit_at_monotonic_ms=15000, monotonic_ms=10000)
            values[-1].update(consistency_count=0, k=1, suppression_enabled=self.mode == 'trickle',
                              reason='ALLOWED', monotonic_ms=15000)
        sequence = 0
        for value in values:
            timestamp = int(value.get("timestamp_ms", 1000) or 1000)
            if timestamp < 1_000_000_000_000:
                value["timestamp_ms"] = base_timestamp + timestamp - 1000
            if (
                self.transport == "serial"
                and value.get("session_id") == session_id
                and value.get("trial_id") == trial_id
            ):
                sequence += 1
                value.setdefault("event_sequence", sequence)
        return values


def standard_provider(outcome_by_attempt=None):
    outcomes = outcome_by_attempt or (lambda _attempt: "SUCCESS")

    def provide(node: FakeNode, session_id: str, trial_id: str) -> list[dict]:
        logical_trial_id = trial_id.split("--", 1)[0]
        attempt = int(logical_trial_id.rsplit("A", 1)[1])
        hypothesis = logical_trial_id.split("-")[1]
        mode = logical_trial_id.split("-")[0]
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
            interval = event(node.node_id, session_id, trial_id, "TRICKLE_INTERVAL_STARTED")
            interval.update(interval_ms=8000, interval_started_at_monotonic_ms=10000,
                            transmit_at_monotonic_ms=14000, monotonic_ms=10000)
            values.append(interval)
            values.append(event(node.node_id, session_id, trial_id, "TRICKLE_CONSISTENT_HEARD"))
            values.append(event(node.node_id, session_id, trial_id, "TRICKLE_TX_SUPPRESSED"))
            values[-1]["monotonic_ms"] = 14000
            values[-1].update(consistency_count=1, k=1, suppression_enabled=True)
        return values

    return provide


def fake_nodes(config: dict, provider=None) -> list[FakeNode]:
    callback = provider or standard_provider()
    return [FakeNode(item, config, callback) for item in config["nodes"]]


class ControllerTest(unittest.TestCase):
    def test_window_starts_at_physical_source_callback_after_long_trickle_wait(self) -> None:
        value = physical_config()
        value['observation_window_seconds'] = 60
        clock = {'wall': 1791027600000, 'mono': 100.0}

        class DelayedSource(FakeNode):
            def command(self, name, arguments):
                if name == 'get_status' and self.node_id == 'android-source':
                    clock['wall'] += 23200
                    clock['mono'] += 23.2
                    self.source_started_at_ms = clock['wall'] - 1200 - 2000
                return super().command(name, arguments)

        def sleep(seconds):
            clock['wall'] += round(seconds * 1000)
            clock['mono'] += seconds

        with tempfile.TemporaryDirectory() as output, \
                patch('resqmesh_controller.controller.time.time_ns', side_effect=lambda: clock['wall'] * 1000000), \
                patch('resqmesh_controller.controller.time.monotonic', side_effect=lambda: clock['mono']):
            nodes = [DelayedSource(item, value, standard_provider()) for item in value['nodes']]
            controller = ExperimentController(value, nodes, Path(output), sleep=sleep)
            # Android's local clock is two seconds behind the host.
            original_sync = controller.synchronize_clocks
            def sync(spec):
                original_sync(spec)
                controller.clock_offsets['android-source'] = 2000
            controller.synchronize_clocks = sync
            result = controller.run_trial(build_plan(value)[0])
            self.assertEqual('SUCCESS', result['result'], result['invalid_reasons'])
            self.assertEqual(result['trigger_requested_at_ms'] + 22000, result['observation_started_at_ms'])
            self.assertEqual(result['observation_started_at_ms'] + 60000, result['observation_ended_at_ms'])
            self.assertEqual(result['observation_ended_at_ms'], result['observation_stop_command_at_ms'])
            self.assertEqual('SOURCE_FIRST_ADVERTISE_STARTED', result['observation_window_basis'])

    def test_missing_source_callback_times_out_and_still_resets_every_node(self) -> None:
        value = physical_config()
        clock = {'mono': 0.0}
        class SilentSource(FakeNode):
            def command(self, name, arguments):
                response = super().command(name, arguments)
                if name == 'get_status':
                    response['source_first_advertise_started_at_ms'] = None
                return response
        def sleep(seconds):
            clock['mono'] += seconds
        with tempfile.TemporaryDirectory() as output, \
                patch('resqmesh_controller.controller.time.monotonic', side_effect=lambda: clock['mono']):
            nodes = [SilentSource(item, value, standard_provider()) for item in value['nodes']]
            controller = ExperimentController(value, nodes, Path(output), sleep=sleep)
            result = controller.run_trial(build_plan(value)[0])
            self.assertEqual('INVALID', result['result'])
            self.assertIn('SOURCE_FIRST_ADVERTISE_STARTED_TIMEOUT', result['invalid_reasons'])
            self.assertNotIn('observation_started_at_ms', result)
            self.assertTrue(all(any(name == 'reset_trial' for name, _ in n.commands) for n in nodes))

    def test_readiness_rejects_old_measurement_build_before_trials(self) -> None:
        value = physical_config()
        class OldBuild(FakeNode):
            def command(self, name, arguments):
                response = super().command(name, arguments)
                response.pop('measurement_timing_version', None)
                return response
        with tempfile.TemporaryDirectory() as output:
            nodes = [OldBuild(item, value, standard_provider()) for item in value['nodes']]
            controller = ExperimentController(value, nodes, Path(output), sleep=lambda _: None)
            with self.assertRaisesRegex(Exception, 'measurement_timing_version'):
                controller.readiness()

    def test_source_callback_from_wrong_trial_or_message_is_rejected(self) -> None:
        value = physical_config()
        for field, invalid_value, reason in [
            ('trial_id', 'previous-trial', 'SOURCE_START_STATUS_SCOPE_MISMATCH'),
            ('source_first_advertise_message_key', 'other:state', 'SOURCE_START_MESSAGE_KEY_MISMATCH'),
        ]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as output:
                class WrongSource(FakeNode):
                    def command(self, name, arguments):
                        response = super().command(name, arguments)
                        if name == 'get_status':
                            response[field] = invalid_value
                        return response
                nodes = [WrongSource(item, value, standard_provider()) for item in value['nodes']]
                controller = ExperimentController(value, nodes, Path(output), sleep=lambda _: None)
                result = controller.run_trial(build_plan(value)[0])
                self.assertEqual('INVALID', result['result'])
                self.assertIn(reason, result['invalid_reasons'])
                self.assertTrue(result['reset_verified'])

    def test_early_relay_burst_invalidates_trial_even_when_delivery_succeeds(self) -> None:
        value = physical_config()
        def provider(node, session_id, trial_id):
            events = standard_provider()(node, session_id, trial_id)
            if node.node_id == 'esp-r1a':
                interval = event(node.node_id, session_id, trial_id, 'TRICKLE_INTERVAL_STARTED')
                interval.update(monotonic_ms=10000, interval_ms=8000,
                                interval_started_at_monotonic_ms=10000,
                                transmit_at_monotonic_ms=15000)
                burst = event(node.node_id, session_id, trial_id, 'ADVERTISE_BURST_STARTED')
                burst.update(monotonic_ms=10017, timestamp_ms=1017)
                ended = event(node.node_id, session_id, trial_id, 'ADVERTISE_BURST_ENDED')
                ended['burst_id'] = burst['burst_id']
                events.extend([interval, burst, ended])
            return events
        with tempfile.TemporaryDirectory() as output:
            controller = ExperimentController(value, fake_nodes(value, provider), Path(output), sleep=lambda _: None)
            spec = next(s for s in build_plan(value) if s.mode == 'trickle' and s.hypothesis == 'H2')
            result = controller.run_trial(spec)
            self.assertEqual('INVALID', result['result'])
            self.assertIn('TRICKLE_TRANSMIT_BEFORE_HALF_INTERVAL:esp-r1a', result['invalid_reasons'])

    def test_radio_configuration_is_sent_and_readiness_saved(self) -> None:
        config = physical_config()
        with tempfile.TemporaryDirectory() as output:
            nodes = fake_nodes(config)
            controller = ExperimentController(config, nodes, Path(output), sleep=lambda _: None)
            spec = build_plan(config)[0]
            controller.configure(spec)
            controller.readiness(spec)
            self.assertEqual("coded", controller.manifest["radio_mode"])
            self.assertEqual(6, len(controller.manifest["radio_readiness"]))
            for node in nodes:
                commands = [args for name, args in node.commands if name == "configure_session"]
                self.assertEqual("coded", commands[0]["radio_mode"])

    def test_radio_mode_changes_research_fingerprint(self) -> None:
        config = physical_config()
        changed = copy.deepcopy(config)
        changed["nodes"][1]["radio_mode"] = "coded_s8_required"
        self.assertNotEqual(research_fingerprint(config), research_fingerprint(changed))

    def test_device_trial_id_is_namespaced_by_session(self) -> None:
        first = physical_config()
        first["session_id"] = "session-one"
        second = copy.deepcopy(first)
        second["session_id"] = "session-two"
        spec = build_plan(first)[0]

        with (
            tempfile.TemporaryDirectory() as first_output,
            tempfile.TemporaryDirectory() as second_output,
        ):
            first_controller = ExperimentController(
                first,
                fake_nodes(first),
                Path(first_output),
                sleep=lambda _: None,
            )
            second_controller = ExperimentController(
                second,
                fake_nodes(second),
                Path(second_output),
                sleep=lambda _: None,
            )

            self.assertNotEqual(
                first_controller._device_trial_id(spec),
                second_controller._device_trial_id(spec),
            )
            self.assertEqual(
                f"{spec.trial_id}--session-one",
                first_controller._device_trial_id(spec),
            )

    def test_run_recovers_interrupted_trial_before_configuring(self) -> None:
        value = physical_config()
        nodes = fake_nodes(value)
        for node in nodes:
            node.session_id = "interrupted-session"
            node.trial_id = "basic_flooding-H2-A001"
            node.reject_configure_while_stale = True

        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(
                value,
                nodes,
                Path(temporary),
                sleep=lambda _: None,
            )
            results = controller.run(limit=1)

            self.assertEqual("SUCCESS", results[0]["result"])
            self.assertEqual(6, len(controller.manifest["startup_recovery"]["states"]))
            for node in nodes:
                command_names = [name for name, _ in node.commands]
                self.assertLess(
                    command_names.index("reset_trial"),
                    command_names.index("configure_session"),
                )
            android = next(node for node in nodes if node.transport == "adb")
            command_names = [name for name, _ in android.commands]
            self.assertLess(
                command_names.index("finalize_trial"),
                command_names.index("reset_trial"),
            )

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

    def test_readiness_rejects_different_rx_burst_gap(self) -> None:
        value = physical_config()
        nodes = fake_nodes(value)
        nodes[0].reported_rx_burst_gap_ms = value["rx_burst_gap_ms"] + 1
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, nodes, Path(temporary), sleep=lambda _: None)
            with self.assertRaisesRegex(Exception, "rx_burst_gap_ms"):
                controller.readiness()

    def test_config_rejects_non_positive_rx_burst_gap(self) -> None:
        value = physical_config()
        value["rx_burst_gap_ms"] = 0
        with self.assertRaisesRegex(ConfigError, "rx_burst_gap_ms"):
            validate_config(value)

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

    def test_default_matrix_contains_135_trials(self) -> None:
        value = physical_config()
        self.assertEqual(135, len(build_plan(value)))
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

    def test_smoke_report_requires_all_nine_conditions(self) -> None:
        value = physical_config()
        value["valid_trials_per_condition"] = 1
        value["max_attempts_per_condition"] = 1
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, fake_nodes(value), Path(temporary), sleep=lambda _: None)
            controller.run()
            report = controller.smoke_report()
            self.assertTrue(report["passed"])
            self.assertEqual(9, len(report["conditions"]))
            self.assertTrue((Path(temporary) / "smoke_report.csv").exists())

    def test_smoke_report_exposes_invalid_trial_reasons(self) -> None:
        value = physical_config()
        spec = build_plan(value)[0]
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(
                value,
                fake_nodes(value, standard_provider(lambda _attempt: "INVALID")),
                Path(temporary),
                sleep=lambda _: None,
            )
            controller.run_trial(spec)

            report = controller.smoke_report()
            condition = next(
                item
                for item in report["conditions"]
                if item["mode"] == spec.mode
                and item["hypothesis"] == spec.hypothesis
            )

            self.assertEqual("INVALID", condition["result"])
            self.assertIn(
                "invalid trial: SIMULATED_INVALID",
                condition["missing_evidence"],
            )

    def test_manifest_trial_record_contains_reconstruction_inputs(self) -> None:
        value = physical_config()
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(value, fake_nodes(value), Path(temporary), sleep=lambda _: None)
            result = controller.run_trial(build_plan(value)[0])
            self.assertEqual(controller.manifest["session_id"], result["session_id"])
            self.assertEqual(
                f"{result['trial_id']}--{controller.manifest['session_id']}",
                result["device_trial_id"],
            )
            self.assertEqual("android-source", result["source_node_id"])
            self.assertEqual(["esp-destination"], result["destination_node_ids"])
            self.assertEqual(1000, result["observation_window_ms"])
            self.assertEqual(
                result["observation_started_at_ms"] + 1000,
                result["observation_ended_at_ms"],
            )
            self.assertTrue(result["require_event_sequence"])
            self.assertTrue(result["require_complete_event_cycles"])
            self.assertEqual(value["clock_tolerance_ms"], result["clock_tolerance_ms"])
            self.assertEqual(value["rx_burst_gap_ms"], result["rx_burst_gap_ms"])
            self.assertEqual("100:200", result["message_key"])
            configure_commands = [
                arguments
                for node in controller.nodes
                for name, arguments in node.commands
                if name == "configure_session"
            ]
            self.assertTrue(configure_commands)
            self.assertTrue(
                all(
                    item["rx_burst_gap_ms"] == value["rx_burst_gap_ms"]
                    for item in configure_commands
                )
            )
            end_window_commands = [
                arguments
                for node in controller.nodes
                for name, arguments in node.commands
                if name == "end_observation_window"
            ]
            self.assertEqual(len(controller.nodes), len(end_window_commands))
            self.assertTrue(
                all(
                    item["observation_ended_at_ms"]
                    == result["observation_ended_at_ms"]
                    for item in end_window_commands
                )
            )


if __name__ == "__main__":
    unittest.main()
