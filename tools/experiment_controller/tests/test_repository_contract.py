import json
import unittest
from pathlib import Path

from resqmesh_controller.config import PHYSICAL_NODE_IDS, validate_config


ROOT = Path(__file__).resolve().parents[3]


class RepositoryContractTest(unittest.TestCase):
    def test_native_usb_cdc_flags_are_guarded(self) -> None:
        platformio = (ROOT / "firmware" / "esp32c3" / "platformio.ini").read_text(
            encoding="utf-8"
        )
        self.assertIn("ARDUINO_USB_MODE=1", platformio)
        self.assertIn("ARDUINO_USB_CDC_ON_BOOT=1", platformio)
        self.assertIn("monitor_dtr = 0", platformio)
        self.assertIn("monitor_rts = 0", platformio)

    def test_template_contains_android_and_five_esp32(self) -> None:
        config = json.loads(
            (ROOT / "tools" / "experiment_controller" / "config.example.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual("<GIT_SHA_12>", config["android_build_id"])
        self.assertEqual("<GIT_SHA_12>", config["firmware_build_id"])
        config["android_build_id"] = "0123456789ab"
        config["firmware_build_id"] = "0123456789ab"
        validate_config(config)
        self.assertEqual(1000, config["rx_burst_gap_ms"])
        self.assertEqual(PHYSICAL_NODE_IDS, {node["node_id"] for node in config["nodes"]})
        ports = [node["port"] for node in config["nodes"] if node["transport"] == "serial"]
        self.assertEqual(5, len(ports))
        self.assertTrue(all(port.startswith("COM_") for port in ports))

    def test_ci_contains_complete_research_validation(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "flutter.yml").read_text(
            encoding="utf-8"
        )
        for command in (
            "dart format --output=none --set-exit-if-changed .",
            "flutter analyze",
            "flutter test",
            "flutter build apk --debug --dart-define=RESQMESH_BUILD_ID=",
            "./gradlew :app:testDebugUnitTest",
            "pytest tools/experiment_controller/tests -q",
            "platformio test -e native",
            "platformio run -e esp32c3",
        ):
            self.assertIn(command, workflow)

    def test_firmware_build_id_and_burst_identity_are_guarded(self) -> None:
        platformio = (ROOT / "firmware" / "esp32c3" / "platformio.ini").read_text(
            encoding="utf-8"
        )
        build_script = (ROOT / "firmware" / "esp32c3" / "build_id.py").read_text(
            encoding="utf-8"
        )
        firmware = (ROOT / "firmware" / "esp32c3" / "src" / "main.cpp").read_text(
            encoding="utf-8"
        )
        self.assertIn("extra_scripts = pre:build_id.py", platformio)
        self.assertIn('git", "rev-parse", "--short=12", "HEAD', build_script)
        self.assertNotIn('#define RESQMESH_FIRMWARE_BUILD_ID "esp32c3-dev"', firmware)
        self.assertNotIn(
            'if (!scheduler.burstId.isEmpty()) document["burst_id"]', firmware
        )
        self.assertIn('if (!burstId.isEmpty()) document["burst_id"]', firmware)
        receive_call = 'emit("BLE_PACKET_RECEIVED", &incoming, nullptr, rssi, observation);'
        self.assertIn(receive_call, firmware)
        self.assertNotIn("lastObservationKey", firmware)
        self.assertNotIn("lastObservationAt", firmware)
        self.assertIn("ObservationTracker observationTracker", firmware)


if __name__ == "__main__":
    unittest.main()
