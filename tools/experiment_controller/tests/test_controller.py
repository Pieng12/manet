import tempfile
import unittest
from pathlib import Path

from resqmesh_controller import PROTOCOL_EPOCH_ID
from resqmesh_controller.controller import ExperimentController, build_plan
from resqmesh_controller.devices import DeviceError, NodeTransport


class FakeNode(NodeTransport):
    def __init__(self, node_id: str, role: str, ready: bool = True) -> None:
        self.node_id = node_id
        self.role = role
        self.ready = ready
        self.commands: list[tuple[str, dict]] = []

    def command(self, name: str, arguments: dict) -> dict:
        self.commands.append((name, arguments))
        if name == "readiness":
            return {
                "ok": True,
                "epoch_id": PROTOCOL_EPOCH_ID,
                "epoch_valid": self.ready,
                "bluetooth": True,
                "permissions": {"scan": True, "advertise": True},
            }
        return {"ok": True, "command_id": arguments.get("command_id")}

    def collect_events(self) -> list[dict]:
        if self.role == "DESTINATION":
            return [{"event_type": "DESTINATION_FIRST_VALID_RECEIVE", "message_key": "1:2"}]
        return []


def config() -> dict:
    return {
        "session_id": "test-session",
        "build_id": "test-build",
        "modes": ["trickle"],
        "hypotheses": ["H1"],
        "trials_per_condition": 1,
        "observation_window_seconds": 0,
        "quiet_period_seconds": 0,
        "nodes": [
            {"node_id": "source", "role": "SOURCE", "topology": {"H1": {"role": "SOURCE"}}},
            {"node_id": "destination", "role": "DESTINATION", "topology": {"H1": {"role": "DESTINATION", "expected_hop_in": 1}}},
        ],
    }


class ControllerTest(unittest.TestCase):
    def test_default_matrix_contains_90_trials(self) -> None:
        value = config() | {
            "modes": ["trickle", "basic_flooding"],
            "hypotheses": ["H1", "H2", "H3"],
            "trials_per_condition": 15,
        }
        self.assertEqual(90, len(build_plan(value)))

    def test_trial_is_resumable_without_second_trigger(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = FakeNode("source", "SOURCE")
            destination = FakeNode("destination", "DESTINATION")
            controller = ExperimentController(config(), [source, destination], Path(temporary), sleep=lambda _: None)
            first = controller.run()
            second = controller.run()

            self.assertEqual("SUCCESS", first[0]["result"])
            self.assertEqual("SUCCESS", second[0]["result"])
            triggers = [name for name, _ in source.commands if name == "trigger_sos"]
            self.assertEqual(["trigger_sos"], triggers)

    def test_readiness_rejects_invalid_epoch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            controller = ExperimentController(config(), [FakeNode("source", "SOURCE", ready=False)], Path(temporary))
            with self.assertRaises(DeviceError):
                controller.readiness()


if __name__ == "__main__":
    unittest.main()
