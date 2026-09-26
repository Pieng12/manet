import unittest

from resqmesh_controller.devices import SerialNode


class FakeConnection:
    def __init__(self) -> None:
        self.writes = []

    def write(self, value: bytes) -> None:
        self.writes.append(value)

    def flush(self) -> None:
        pass


class DeviceTransportTest(unittest.TestCase):
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
