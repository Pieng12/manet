import unittest

from resqmesh_controller.radio import radio_readiness_errors


class RadioReadinessTests(unittest.TestCase):
    def radio(self):
        return dict(ready=True, primary_phy="coded", secondary_phy="coded",
                    scan_phy="coded", requested_mode="coded", advertising_interval_units=400,
                    coding_selection_support="unsupported", s8_requirement_accepted=False,
                    on_air_coding_verified=False)

    def test_plain_coded_is_valid_without_s8_evidence(self):
        self.assertEqual([], radio_readiness_errors(self.radio(), "coded"))

    def test_required_s8_rejects_android_and_missing_telemetry(self):
        self.assertTrue(radio_readiness_errors(self.radio(), "coded_s8_required"))
        self.assertTrue(radio_readiness_errors(None, "coded"))

    def test_s8_controller_acceptance_is_not_on_air_verification(self):
        radio = self.radio()
        radio.update(requested_mode="coded_s8_required", coding_selection_support="supported",
                     s8_requirement_accepted=True)
        self.assertEqual([], radio_readiness_errors(radio, "coded_s8_required"))
        self.assertFalse(radio["on_air_coding_verified"])

    def test_legacy_phy_or_changed_radio_interval_rejected(self):
        radio = self.radio()
        radio.update(primary_phy="1m", advertising_interval_units=1600)
        self.assertEqual(2, len(radio_readiness_errors(radio, "coded")))
