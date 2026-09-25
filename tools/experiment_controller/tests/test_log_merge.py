import json
import tempfile
import unittest
from pathlib import Path

from resqmesh_controller.log_merge import aggregate, deduplicate, merge_directory, numeric_stats, summarize_trial


class LogMergeTest(unittest.TestCase):
    def test_canonical_events_are_deduplicated(self) -> None:
        event = {"node_id": "R1", "event_type": "BLE_PACKET_RECEIVED", "event_key": "BLE_PACKET_RECEIVED|obs-1"}
        self.assertEqual(1, len(deduplicate([event, dict(event)])))

    def test_metrics_follow_research_formulas(self) -> None:
        summary = summarize_trial(
            "trial-1",
            [
                {"event_type": "BLE_PACKET_ACCEPTED"},
                {"event_type": "BLE_PACKET_DUPLICATE"},
                {"event_type": "BLE_PACKET_DUPLICATE"},
                {"event_type": "ADVERTISE_BURST_STARTED", "node_id": "R1", "burst_id": "b1", "packet_type": "sos"},
                {"event_type": "DESTINATION_FIRST_VALID_RECEIVE"},
            ],
            {"result": "SUCCESS", "mode": "trickle", "hypothesis": "H2"},
        )
        failed = summary | {"trial_id": "trial-2", "result": "FAILED_DELIVERY", "transmission_bursts": 3}
        group = aggregate([summary, failed])[0]

        self.assertAlmostEqual(2 / 3, summary["ldr"])
        self.assertAlmostEqual(0.5, group["dsr"])
        self.assertAlmostEqual(2.0, group["transmission_overhead"])

    def test_zero_ldr_denominator_is_null_and_stats_are_complete(self) -> None:
        summary = summarize_trial("empty", [], {"result": "FAILED_DELIVERY"})
        stats = numeric_stats([1, 2, 3, 4])
        self.assertIsNone(summary["ldr"])
        self.assertEqual(4, stats["count"])
        self.assertEqual(1, stats["min"])
        self.assertEqual(4, stats["max"])
        self.assertEqual(2.5, stats["median"])
        self.assertIsNotNone(stats["sample_stddev"])
        self.assertEqual(stats["q3"] - stats["q1"], stats["iqr"])

    def test_e2e_uses_clock_offsets_only_when_sync_is_valid(self) -> None:
        synchronized = summarize_trial(
            "synced",
            [
                {
                    "event_type": "SOURCE_FIRST_ADVERTISE_STARTED",
                    "message_key": "1:2",
                    "timestamp_ms": 1000,
                    "clock_sync_valid": True,
                    "clock_offset_ms": 50,
                },
                {
                    "event_type": "DESTINATION_FIRST_VALID_RECEIVE",
                    "message_key": "1:2",
                    "timestamp_ms": 1400,
                    "clock_sync_valid": True,
                    "clock_offset_ms": -50,
                },
            ],
            {"result": "SUCCESS"},
        )
        unsynchronized = summarize_trial(
            "unsynced",
            [
                {
                    "event_type": "SOURCE_FIRST_ADVERTISE_STARTED",
                    "message_key": "1:2",
                    "timestamp_ms": 1000,
                },
                {
                    "event_type": "DESTINATION_FIRST_VALID_RECEIVE",
                    "message_key": "1:2",
                    "timestamp_ms": 1400,
                },
            ],
            {"result": "SUCCESS"},
        )

        self.assertEqual(300, synchronized["e2e_latency_ms"])
        self.assertIsNone(unsynchronized["e2e_latency_ms"])

    def test_merge_writes_all_required_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "raw" / "trial-1"
            raw.mkdir(parents=True)
            event = {"trial_id": "trial-1", "node_id": "D", "event_type": "DESTINATION_FIRST_VALID_RECEIVE", "event_key": "dest|1"}
            (raw / "D.jsonl").write_text(json.dumps(event) + "\n" + json.dumps(event) + "\n", encoding="utf-8")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"trials": {"trial-1": {"result": "SUCCESS", "mode": "trickle", "hypothesis": "H1"}}}), encoding="utf-8")
            output = root / "merged"

            result = merge_directory(root / "raw", output, manifest)

            self.assertEqual(1, result["events"])
            for name in ("events.json", "events.csv", "trial_summary.csv", "aggregate_by_mode_hop.csv", "invalid_trials.csv"):
                self.assertTrue((output / name).exists(), name)


if __name__ == "__main__":
    unittest.main()
