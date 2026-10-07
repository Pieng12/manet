import sys
import unittest
from unittest.mock import patch

from resqmesh_controller.devices import AdbNode, SerialNode, DeviceError, _run


class FakeConnection:
    def __init__(self) -> None:
        self.writes = []

    def write(self, value: bytes) -> None:
        self.writes.append(value)

    def flush(self) -> None:
        pass


class DeviceTransportTest(unittest.TestCase):
    def test_serial_disconnect_notifies_and_preserves_partial_raw_evidence(self):
        node = SerialNode("esp-r2a", "RELAY", "COM_TEST")
        node._events.append({'session_id':'s','trial_id':'t','event_type':'DATA_RECEIVED'})
        class BrokenConnection:
            def readline(self):
                raise PermissionError('device disappeared')
        node._reader_loop(BrokenConnection())
        self.assertIn('device disappeared',node.transport_error)
        with self.assertRaises(DeviceError): node.command('readiness',{})
        with self.assertRaises(DeviceError): node.collect_events('s','t')
        self.assertEqual(1,len(node.diagnostic_events('s','t')))

    def test_adb_events_are_read_from_durable_export(self) -> None:
        node = AdbNode("android-source", "SOURCE", "SERIAL")
        node.command = lambda name, arguments: {
            "ok": True,
            "json_path": "/data/user/0/id.ac.usu.resqmesh/app_flutter/trial.json",
        }
        exported = {
            "session": {"device_id": "android-source"},
            "events": [
                {
                    "session_id": "session-1",
                    "trial_id": "trial-1",
                    "event_type": "SOURCE_FIRST_ADVERTISE_STARTED",
                },
                {
                    "session_id": "old-session",
                    "trial_id": "trial-1",
                    "event_type": "BLE_ADVERTISE_STARTED",
                },
            ]
        }

        with patch(
            "resqmesh_controller.devices._run",
            return_value=__import__("json").dumps(exported),
        ) as run:
            events = node.collect_events("session-1", "trial-1")

        self.assertEqual(1, len(events))
        self.assertEqual("SOURCE_FIRST_ADVERTISE_STARTED", events[0]["event_type"])
        self.assertEqual("android-source", events[0]["node_id"])
        self.assertEqual("android-source", events[0]["device_id"])
        self.assertEqual("exec-out", run.call_args.args[0][3])
        self.assertEqual("app_flutter/trial.json", run.call_args.args[0][-1])

    def test_subprocess_output_replaces_non_utf8_bytes(self) -> None:
        output = _run(
            [
                sys.executable,
                "-c",
                "import sys; sys.stdout.buffer.write(bytes([0x8f]))",
            ]
        )

        self.assertEqual("\ufffd", output)

    def test_serial_command_response_and_event_are_not_mixed(self) -> None:
        node = SerialNode("esp-r1a", "RELAY", "COM_TEST")
        connection = FakeConnection()
        node._connection = lambda: connection
        node._events.append(
            {
                "kind": "event",
                "session_id": "s1",
                "trial_id": "t1",
                "event_type": "BLE_PACKET_RECEIVED",
            }
        )
        node._responses.append(
            {"kind": "response", "command_id": "ready-1", "ok": True}
        )

        response = node.command("readiness", {"command_id": "ready-1"})
        events = node.collect_events(session_id="s1", trial_id="t1")

        self.assertTrue(response["ok"])
        self.assertEqual("BLE_PACKET_RECEIVED", events[0]["event_type"])
        self.assertEqual(1, len(connection.writes))


if __name__ == "__main__":
    unittest.main()
