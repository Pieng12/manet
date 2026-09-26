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
        validate_config(config)
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
            "flutter build apk --debug",
            "./gradlew :app:testDebugUnitTest",
            "unittest discover",
            "platformio test -e native",
            "platformio run -e esp32c3",
        ):
            self.assertIn(command, workflow)


if __name__ == "__main__":
    unittest.main()
