import json
import tempfile
import unittest
from pathlib import Path

from resqmesh_controller.log_merge import (
    aggregate,
    deduplicate,
    merge_directory,
    numeric_stats,
    summarize_trial,
)


def trial_event(event_type: str, **values) -> dict:
    return {
        "session_id": "session-1",
        "trial_id": "trial-1",
        "node_id": "R1",
        "event_type": event_type,
        **values,
    }


class LogMergeTest(unittest.TestCase):
    def test_canonical_events_are_deduplicated(self) -> None:
        value = trial_event(
            "BLE_PACKET_RECEIVED",
            event_key="BLE_PACKET_RECEIVED|obs-1",
        )
        self.assertEqual(1, len(deduplicate([value, dict(value)])))

    def test_metrics_follow_research_formulas_and_ignore_requested_burst(self) -> None:
        events = [
            trial_event("BLE_PACKET_ACCEPTED"),
            trial_event("BLE_PACKET_DUPLICATE"),
            trial_event("BLE_PACKET_DUPLICATE", timestamp_ms=2),
            trial_event("ADVERTISE_BURST_REQUESTED", burst_id="requested", packet_type="sos"),
            trial_event("ADVERTISE_BURST_STARTED", burst_id="b1", packet_type="sos"),
            trial_event("ADVERTISE_BURST_STARTED", burst_id="", packet_type="sos"),
            trial_event("DESTINATION_FIRST_VALID_RECEIVE"),
        ]
        record = {"result": "SUCCESS", "mode": "trickle", "hypothesis": "H2", "session_id": "session-1"}
        summary = summarize_trial("trial-1", events, record)
        failed = summary | {"trial_id": "trial-2", "result": "FAILED_DELIVERY", "transmission_bursts": 3}
        group = aggregate([summary, failed])[0]

        self.assertAlmostEqual(2 / 3, summary["ldr"])
        self.assertEqual(1, summary["transmission_bursts"])
        self.assertAlmostEqual(0.5, group["dsr"])
        self.assertAlmostEqual(2.0, group["transmission_overhead"])

    def test_e2e_requires_matching_nodes_message_hop_and_clock(self) -> None:
        record = {
            "result": "SUCCESS",
            "session_id": "session-1",
            "observation_window_ms": 5000,
            "evidence": {
                "source_node_id": "source",
                "destination_node_ids": ["destination"],
                "expected_hop_in": 3,
                "message_key": "1:2",
            },
        }
        events = [
            trial_event(
                "SOURCE_FIRST_ADVERTISE_STARTED",
                node_id="source",
                message_key="1:2",
                timestamp_ms=1000,
                clock_sync_valid=True,
                clock_offset_ms=50,
            ),
            trial_event(
                "DESTINATION_FIRST_VALID_RECEIVE",
                node_id="wrong-destination",
                message_key="1:2",
                hop_in=3,
                timestamp_ms=1200,
                clock_sync_valid=True,
            ),
            trial_event(
                "DESTINATION_FIRST_VALID_RECEIVE",
                node_id="destination",
                message_key="other",
                hop_in=3,
                timestamp_ms=1250,
                clock_sync_valid=True,
            ),
            trial_event(
                "DESTINATION_FIRST_VALID_RECEIVE",
                node_id="destination",
                message_key="1:2",
                hop_in=2,
                timestamp_ms=1300,
                clock_sync_valid=True,
            ),
            trial_event(
                "DESTINATION_FIRST_VALID_RECEIVE",
                node_id="destination",
                message_key="1:2",
                hop_in=3,
                timestamp_ms=1400,
                clock_sync_valid=True,
                clock_offset_ms=-50,
            ),
        ]
        summary = summarize_trial("trial-1", events, record)
        self.assertEqual(300, summary["e2e_latency_ms"])

    def test_negative_or_unsynchronized_latency_is_rejected(self) -> None:
        record = {
            "result": "SUCCESS",
            "session_id": "session-1",
            "evidence": {
                "source_node_id": "source",
                "destination_node_ids": ["destination"],
                "expected_hop_in": 1,
                "message_key": "1:2",
            },
        }
        events = [
            trial_event(
                "SOURCE_FIRST_ADVERTISE_STARTED",
                node_id="source",
                message_key="1:2",
                timestamp_ms=2000,
                clock_sync_valid=True,
            ),
            trial_event(
                "DESTINATION_FIRST_VALID_RECEIVE",
                node_id="destination",
                message_key="1:2",
                hop_in=1,
                timestamp_ms=1000,
                clock_sync_valid=True,
            ),
        ]
        self.assertIsNone(summarize_trial("trial-1", events, record)["e2e_latency_ms"])

    def test_zero_ldr_denominator_is_null_and_stats_are_complete(self) -> None:
        summary = summarize_trial("trial-1", [], {"result": "FAILED_DELIVERY"})
        stats = numeric_stats([1, 2, 3, 4])
        self.assertIsNone(summary["ldr"])
        self.assertEqual(4, stats["count"])
        self.assertEqual(2.5, stats["median"])
        self.assertIsNotNone(stats["sample_stddev"])
        self.assertEqual(stats["q3"] - stats["q1"], stats["iqr"])

    def test_merge_filters_other_sessions_and_writes_required_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "raw" / "trial-1"
            raw.mkdir(parents=True)
            current = trial_event(
                "DESTINATION_FIRST_VALID_RECEIVE",
                node_id="destination",
                event_key="dest|1",
            )
            old = current | {"session_id": "old-session", "event_key": "dest|old"}
            (raw / "D.jsonl").write_text(
                json.dumps(current) + "\n" + json.dumps(current) + "\n" + json.dumps(old) + "\n",
                encoding="utf-8",
            )
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "session_id": "session-1",
                        "trials": {
                            "trial-1": {
                                "result": "SUCCESS",
                                "mode": "trickle",
                                "hypothesis": "H1",
                                "attempt": 1,
                                "terminal": True,
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            output = root / "merged"
            result = merge_directory(root / "raw", output, manifest)
            self.assertEqual(1, result["events"])
            for name in (
                "events.json",
                "events.csv",
                "trial_summary.csv",
                "aggregate_by_mode_hop.csv",
                "invalid_trials.csv",
                "attempt_summary.csv",
            ):
                self.assertTrue((output / name).exists(), name)


if __name__ == "__main__":
    unittest.main()
