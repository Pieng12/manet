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


def valid_record(result: str = "SUCCESS", **values) -> dict:
    return {
        "result": result,
        "mode": "trickle",
        "hypothesis": "H2",
        "session_id": "session-1",
        "source_node_id": "source",
        "destination_node_ids": ["destination"],
        "expected_hop_in": 2,
        "message_key": "1:2",
        "observation_window_ms": 1000,
        "clock_tolerance_ms": 100,
        **values,
    }


def delivery_events(*, source_time: int = 1000, destination_time: int = 1300) -> list[dict]:
    return [
        trial_event(
            "SOURCE_FIRST_ADVERTISE_STARTED",
            node_id="source",
            message_key="1:2",
            timestamp_ms=source_time,
            clock_sync_valid=True,
            burst_id="source-burst",
        ),
        trial_event(
            "DESTINATION_FIRST_VALID_RECEIVE",
            node_id="destination",
            message_key="1:2",
            hop_in=2,
            timestamp_ms=destination_time,
            clock_sync_valid=True,
            observation_id="destination-observation",
        ),
    ]


class LogMergeTest(unittest.TestCase):
    def test_event_identity_is_scoped_and_exact_copies_are_deduplicated(self) -> None:
        value = trial_event("ADVERTISE_BURST_STARTED", burst_id="same")
        other_trial = value | {"trial_id": "trial-2"}
        other_node = value | {"node_id": "R2"}
        self.assertEqual(3, len(deduplicate([value, dict(value), other_trial, other_node])))

    def test_distinct_duplicate_observations_remain_distinct(self) -> None:
        events = delivery_events() + [
            trial_event("BLE_PACKET_ACCEPTED", observation_id="accepted-1"),
            trial_event("BLE_PACKET_DUPLICATE", observation_id="duplicate-1"),
            trial_event("BLE_PACKET_DUPLICATE", observation_id="duplicate-2"),
        ]
        summary = summarize_trial("trial-1", events, valid_record())
        self.assertEqual(2, summary["duplicates"])
        self.assertAlmostEqual(2 / 3, summary["ldr"])

    def test_metrics_follow_research_formulas_and_ignore_requested_burst(self) -> None:
        events = delivery_events() + [
            trial_event("BLE_PACKET_ACCEPTED", observation_id="a1"),
            trial_event("BLE_PACKET_DUPLICATE", observation_id="d1"),
            trial_event("BLE_PACKET_DUPLICATE", observation_id="d2"),
            trial_event("ADVERTISE_BURST_REQUESTED", burst_id="requested", packet_type="sos"),
            trial_event("ADVERTISE_BURST_STARTED", burst_id="b1", packet_type="sos"),
            trial_event("ADVERTISE_BURST_STARTED", burst_id="", packet_type="sos"),
        ]
        summary = summarize_trial("trial-1", events, valid_record())
        failed = summary | {
            "trial_id": "trial-2",
            "result": "FAILED_DELIVERY",
            "transmission_bursts": 3,
        }
        group = aggregate([summary, failed])[0]

        self.assertAlmostEqual(2 / 3, summary["ldr"])
        self.assertEqual(1, summary["transmission_bursts"])
        self.assertAlmostEqual(0.5, group["dsr"])
        self.assertAlmostEqual(2.0, group["transmission_overhead"])

    def test_observation_window_boundary_and_out_of_range(self) -> None:
        boundary = summarize_trial(
            "trial-1", delivery_events(destination_time=2100), valid_record()
        )
        self.assertEqual(1100, boundary["e2e_latency_ms"])
        self.assertEqual("SUCCESS", boundary["result"])

        outside = summarize_trial(
            "trial-1", delivery_events(destination_time=2101), valid_record()
        )
        self.assertEqual("INVALID", outside["result"])
        self.assertIn("E2E_LATENCY_OUT_OF_RANGE", outside["invalid_reasons"])

    def test_missing_zero_or_negative_observation_window_is_invalid(self) -> None:
        for window in (None, 0, -1):
            record = valid_record()
            if window is None:
                record.pop("observation_window_ms")
            else:
                record["observation_window_ms"] = window
            with self.subTest(window=window):
                summary = summarize_trial("trial-1", delivery_events(), record)
                self.assertEqual("INVALID", summary["result"])
                self.assertIn("OBSERVATION_WINDOW_INVALID", summary["invalid_reasons"])

    def test_negative_or_unsynchronized_latency_is_invalid(self) -> None:
        negative = summarize_trial(
            "trial-1",
            delivery_events(source_time=2000, destination_time=1000),
            valid_record(),
        )
        self.assertEqual("INVALID", negative["result"])
        self.assertIn("E2E_LATENCY_NEGATIVE", negative["invalid_reasons"])

        unsynchronized = delivery_events()
        unsynchronized[1]["clock_sync_valid"] = False
        summary = summarize_trial("trial-1", unsynchronized, valid_record())
        self.assertEqual("INVALID", summary["result"])
        self.assertIn("CLOCK_SYNC_INVALID", summary["invalid_reasons"])

    def test_source_destination_message_and_hop_mismatch_are_invalid(self) -> None:
        mutations = {
            "source": (0, "node_id", "wrong-source"),
            "destination": (1, "node_id", "wrong-destination"),
            "message": (1, "message_key", "other-message"),
            "hop": (1, "hop_in", 3),
        }
        for name, (index, key, value) in mutations.items():
            events = delivery_events()
            events[index][key] = value
            with self.subTest(name=name):
                summary = summarize_trial("trial-1", events, valid_record())
                self.assertEqual("INVALID", summary["result"])

    def test_controller_and_reconstructed_latency_mismatch_is_invalid(self) -> None:
        record = valid_record(evidence={"e2e_latency_ms": 999})
        summary = summarize_trial("trial-1", delivery_events(), record)
        self.assertEqual("INVALID", summary["result"])
        self.assertIn("CONTROLLER_LOG_EVIDENCE_MISMATCH", summary["invalid_reasons"])

    def test_zero_ldr_denominator_is_null_and_stats_are_complete(self) -> None:
        summary = summarize_trial(
            "trial-1",
            [delivery_events()[0]],
            valid_record(result="FAILED_DELIVERY"),
        )
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
            current_events = delivery_events()
            old = current_events[1] | {
                "session_id": "old-session",
                "observation_id": "old-observation",
            }
            lines = current_events + [dict(current_events[1]), old]
            (raw / "D.jsonl").write_text(
                "".join(json.dumps(item) + "\n" for item in lines),
                encoding="utf-8",
            )
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "session_id": "session-1",
                        "trials": {
                            "trial-1": valid_record(
                                attempt=1,
                                terminal=True,
                                evidence={"e2e_latency_ms": 300},
                            )
                        },
                    }
                ),
                encoding="utf-8",
            )
            output = root / "merged"
            result = merge_directory(root / "raw", output, manifest)
            self.assertEqual(2, result["events"])
            self.assertEqual(0, result["invalid"])
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
