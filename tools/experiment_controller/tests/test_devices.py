import sys
import json
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
    def read_serial_chunks(self, chunks):
        node = SerialNode("esp-r1a", "RELAY", "COM_TEST")
        values = iter(chunks)
        class ChunkedConnection:
            def readline(self):
                try:
                    return next(values)
                except StopIteration:
                    node._stop_reader.set()
                    return b""
        node._reader_loop(ChunkedConnection())
        return node

    def test_serial_partial_response_survives_read_timeout(self):
        node = self.read_serial_chunks([
            b'{"kind":"response","command_id":"end-1",', b"",
            b'"ok":true}\n',
        ])
        self.assertEqual(1, len(node._responses))
        self.assertEqual("end-1", node._responses[0]["command_id"])
        self.assertTrue(node._responses[0]["ok"])
        connection = FakeConnection()
        node._connection = lambda: connection
        response = node.command("end_observation_window", {"command_id":"end-1"})
        self.assertTrue(response["ok"])
        self.assertEqual(0, len(node._responses))

    def test_serial_busy_event_stream_preserves_response_and_all_sequences(self):
        events=[{"kind":"event","event_type":"DATA_RECEIVED","event_sequence":s,
                 "session_id":"s","trial_id":"t"} for s in range(1,301)]
        response={"kind":"response","command_id":"reset-busy","ok":True}
        stream=b"".join((json.dumps(v)+"\n").encode() for v in events+[response])
        chunks=[]
        for at in range(0,len(stream),97):
            chunks.extend([stream[at:at+97],b""])
        node=self.read_serial_chunks(chunks)
        connection=FakeConnection()
        node._connection=lambda:connection
        self.assertTrue(node.command("reset_trial",{"command_id":"reset-busy"})['ok'])
        self.assertEqual(events,node.collect_events("s","t"))
        self.assertEqual(0,node.pending_serial_bytes)
        self.assertEqual(0,node.malformed_line_count)

    def test_serial_partial_event_and_split_utf8_preserve_evidence(self):
        node = self.read_serial_chunks([
            b'{"kind":"event","event_type":"DATA_RECEIVED","note":"caf\xc3',
            b"", b'\xa9","event_sequence":42}\n',
        ])
        self.assertEqual(1, len(node._events))
        self.assertEqual("caf\u00e9", node._events[0]["note"])
        self.assertEqual(42, node._events[0]["event_sequence"])

    def test_serial_invalid_complete_line_does_not_corrupt_next_response(self):
        node = self.read_serial_chunks([
            b'{"bad":\n', b'{"kind":"response","command_id":"reset-1","ok":true}\n',
        ])
        self.assertEqual(1, len(node._responses))
        self.assertEqual("reset-1", node._responses[0]["command_id"])
        self.assertEqual(1, node.malformed_line_count)

    def test_serial_incomplete_line_is_not_counted_as_received_event(self):
        node = self.read_serial_chunks([b'{"kind":"event","event_type":"DATA_RECEIVED"'])
        self.assertEqual([], node._events)
        self.assertEqual(0, len(node._responses))
        self.assertGreater(node.pending_serial_bytes, 0)

    def test_adb_neighbor_adjacency_uses_string_array_without_signed_id_overflow(self):
        from resqmesh_controller.neighbor_experiment import SOURCE, adjacency
        node = AdbNode(SOURCE, "SOURCE", "SERIAL")
        with patch("resqmesh_controller.devices._run", side_effect=["", '{"ok":true,"command_id":"cfg-array"}']) as run:
            result = node.command("configure_session", {
                "command_id": "cfg-array", "node_id": SOURCE,
                "allowed_transmitters": adjacency(SOURCE), "main_experiment": True,
                "observation_window_ms": 180000, "protocol_timestamp_ms": 1791400000000})
        self.assertTrue(result["ok"])
        argv = run.call_args_list[0].args[0]
        index = argv.index("allowed_transmitters")
        self.assertEqual(["--esa", "allowed_transmitters", "3376660029,1347088263"], argv[index-1:index+2])
        for key, flag in (("main_experiment", "--ez"), ("observation_window_ms", "--ei"), ("protocol_timestamp_ms", "--el")):
            self.assertEqual(flag, argv[argv.index(key)-1])

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
