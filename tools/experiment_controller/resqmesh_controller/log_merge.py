from __future__ import annotations

import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

from .excel_report import WORKBOOK_NAME, write_analysis_workbook


METRIC_EVENT_TYPES = {
    "ADVERTISE_BURST_STARTED",
    "BLE_PACKET_ACCEPTED",
    "BLE_PACKET_DUPLICATE",
    "DESTINATION_FIRST_VALID_RECEIVE",
    "SOURCE_FIRST_ADVERTISE_STARTED",
    "TRICKLE_CONSISTENT_HEARD",
    "TRICKLE_TX_SUPPRESSED",
}


def read_json_events(paths: Iterable[Path]) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for path in paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            start = line.find("{")
            if start < 0:
                continue
            try:
                value = json.loads(line[start:])
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict) and value.get("event_type"):
                events.append(value)
    return events


def event_identity(event: dict[str, Any]) -> tuple[Any, ...]:
    node = event.get("node_id", event.get("device_id"))
    scope = (
        event.get("session_id"),
        event.get("trial_id"),
        node,
        event.get("event_type"),
    )
    if event.get("event_key"):
        return (*scope, "event_key", event["event_key"])
    if event.get("observation_id"):
        return (*scope, "observation_id", event["observation_id"])
    if event.get("burst_id"):
        return (*scope, "burst_id", event["burst_id"])
    canonical_payload = json.dumps(
        event,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )
    return (*scope, "canonical_payload", canonical_payload)


def deduplicate(events: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    unique: dict[tuple[Any, ...], dict[str, Any]] = {}
    for event in events:
        unique.setdefault(event_identity(event), event)
    return sorted(
        unique.values(),
        key=lambda item: (
            str(item.get("trial_id", "")),
            int(item.get("timestamp_ms", item.get("event_timestamp_ms", 0)) or 0),
            str(item.get("node_id", item.get("device_id", ""))),
        ),
    )


def numeric_stats(values: list[float]) -> dict[str, float | int | None]:
    ordered = sorted(values)
    if not ordered:
        return {key: None for key in ("min", "max", "mean", "median", "sample_stddev", "q1", "q3", "iqr")} | {"count": 0}
    midpoint = len(ordered) // 2
    lower = ordered[:midpoint] if len(ordered) > 1 else ordered
    upper = ordered[(len(ordered) + 1) // 2 :] if len(ordered) > 1 else ordered
    q1 = statistics.median(lower)
    q3 = statistics.median(upper)
    return {
        "count": len(ordered),
        "min": min(ordered),
        "max": max(ordered),
        "mean": statistics.fmean(ordered),
        "median": statistics.median(ordered),
        "sample_stddev": statistics.stdev(ordered) if len(ordered) > 1 else None,
        "q1": q1,
        "q3": q3,
        "iqr": q3 - q1,
    }


def _timestamp(event: dict[str, Any]) -> int | None:
    value = event.get("event_timestamp_ms", event.get("timestamp_ms"))
    if value is None:
        return None
    if event.get("clock_sync_valid") is not True:
        return None
    offset = event.get("clock_offset_ms", 0)
    return int(round(float(value) + float(offset)))


def event_within_observation_window(
    event: dict[str, Any],
    record: dict[str, Any],
) -> bool:
    start = record.get("observation_started_at_ms")
    end = record.get("observation_ended_at_ms")
    if start is None or end is None:
        return True
    timestamp = _timestamp(event)
    if timestamp is None:
        return False
    return int(start) <= timestamp <= int(end)


def research_event_integrity_errors(
    events: list[dict[str, Any]],
    record: dict[str, Any],
) -> set[str]:
    errors: set[str] = set()
    if record.get("require_event_sequence") is True:
        for node_id in record.get("event_sequence_node_ids", []):
            node_events = [
                event
                for event in events
                if event.get("node_id", event.get("device_id")) == node_id
            ]
            sequences: list[int] = []
            for event in node_events:
                try:
                    sequences.append(int(event["event_sequence"]))
                except (KeyError, TypeError, ValueError):
                    errors.add(f"EVENT_SEQUENCE_MISSING:{node_id}")
            if len(sequences) != len(set(sequences)):
                errors.add(f"EVENT_SEQUENCE_DUPLICATE:{node_id}")
            ordered = sorted(set(sequences))
            if any(current != previous + 1 for previous, current in zip(ordered, ordered[1:])):
                errors.add(f"EVENT_SEQUENCE_GAP:{node_id}")

    if record.get("require_complete_event_cycles") is True:
        received = {
            (
                event.get("node_id", event.get("device_id")),
                event.get("observation_id"),
            )
            for event in events
            if event.get("event_type") == "BLE_PACKET_RECEIVED"
            and event.get("observation_id") not in (None, "")
        }
        for event in events:
            if event.get("event_type") != "BLE_PACKET_DUPLICATE":
                continue
            node_id = event.get("node_id", event.get("device_id"))
            observation_id = event.get("observation_id")
            if observation_id in (None, ""):
                errors.add(f"DUPLICATE_OBSERVATION_ID_MISSING:{node_id}")
            elif (node_id, observation_id) not in received:
                errors.add(f"DUPLICATE_RECEIVE_EVENT_MISSING:{node_id}")

        terminal_bursts = {
            (
                event.get("node_id", event.get("device_id")),
                event.get("burst_id"),
            )
            for event in events
            if event.get("event_type")
            in {"ADVERTISE_BURST_ENDED", "ADVERTISE_BURST_CANCELLED"}
            and event.get("burst_id") not in (None, "")
        }
        for event in events:
            if event.get("event_type") != "ADVERTISE_BURST_STARTED":
                continue
            node_id = event.get("node_id", event.get("device_id"))
            burst_id = event.get("burst_id")
            if burst_id in (None, "") or (node_id, burst_id) not in terminal_bursts:
                errors.add(f"BURST_TERMINAL_EVENT_MISSING:{node_id}")
    return errors


def _hop(event: dict[str, Any]) -> int | None:
    try:
        return int(event.get("hop_in", event.get("hop_count", -1)))
    except (TypeError, ValueError):
        return None


def canonical_message_key(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value)
    try:
        sender_crc, timestamp = text.split(":", 1)
        timestamp_value = int(timestamp)
    except (TypeError, ValueError):
        return text
    if 1_000_000_000 <= abs(timestamp_value) < 100_000_000_000:
        timestamp_value *= 1000
    return f"{sender_crc}:{timestamp_value}"


def canonical_state_identity(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value)
    parts = text.split(":")
    if len(parts) != 5:
        return text
    message_key = canonical_message_key(":".join(parts[:2]))
    return f"{message_key}:{':'.join(parts[2:])}"


def _transmit_hop(event: dict[str, Any]) -> int | None:
    for field in ("hop_out", "hop_in", "hop_count"):
        try:
            value = event.get(field)
            if value is not None:
                return int(value)
        except (TypeError, ValueError):
            continue
    return None


def latency_diagnostics(
    events: list[dict[str, Any]],
    *,
    source_node: str | None,
    destination_nodes: set[str],
    expected_hop: int,
    message_key: str | None,
) -> dict[str, Any]:
    diagnostics: dict[str, Any] = {
        "source_bursts_before_destination": None,
        "delivery_after_last_source_burst_ms": None,
        "source_attempt_index_to_hop1_accept": None,
        "source_first_attempt_success": None,
        "source_retry_wait_ms": None,
        "hop1_accept_after_source_burst_ms": None,
    }
    for hop in range(1, 4):
        diagnostics.update(
            {
                f"hop{hop}_first_accept_elapsed_ms": None,
                f"hop{hop}_segment_progress_ms": None,
                f"hop{hop}_upstream_bursts_before_accept": None,
                f"hop{hop}_attribution": None,
            }
        )

    if not source_node or not destination_nodes or expected_hop < 1 or not message_key:
        return diagnostics

    message_events = [
        event
        for event in events
        if event.get("message_key") == message_key
        and event.get("packet_type", "sos") == "sos"
    ]
    source_times = [
        timestamp
        for event in message_events
        if event.get("event_type") == "SOURCE_FIRST_ADVERTISE_STARTED"
        and event.get("node_id", event.get("device_id")) == source_node
        and (timestamp := _timestamp(event)) is not None
    ]
    if not source_times:
        return diagnostics
    source_time = min(source_times)

    source_bursts = sorted(
        (
            timestamp,
            str(event.get("burst_id")),
        )
        for event in message_events
        if event.get("event_type") == "ADVERTISE_BURST_STARTED"
        and event.get("node_id", event.get("device_id")) == source_node
        and event.get("burst_id") not in (None, "")
        and (timestamp := _timestamp(event)) is not None
    )
    destination_times = [
        timestamp
        for event in message_events
        if event.get("event_type") == "DESTINATION_FIRST_VALID_RECEIVE"
        and event.get("node_id", event.get("device_id")) in destination_nodes
        and _hop(event) == expected_hop
        and (timestamp := _timestamp(event)) is not None
    ]
    if destination_times:
        destination_time = min(destination_times)
        bursts_before_destination = [
            timestamp for timestamp, _ in source_bursts if timestamp <= destination_time
        ]
        diagnostics["source_bursts_before_destination"] = len(
            bursts_before_destination
        )
        if bursts_before_destination:
            diagnostics["delivery_after_last_source_burst_ms"] = (
                destination_time - bursts_before_destination[-1]
            )

    first_accept_by_hop: dict[int, int] = {}
    for hop in range(1, expected_hop + 1):
        accept_times = [
            timestamp
            for event in message_events
            if event.get("event_type") == "BLE_PACKET_ACCEPTED"
            and _hop(event) == hop
            and (timestamp := _timestamp(event)) is not None
        ]
        if accept_times:
            first_accept_by_hop[hop] = min(accept_times)

    previous_arrival = source_time
    for hop in range(1, min(expected_hop, 3) + 1):
        accept_time = first_accept_by_hop.get(hop)
        if accept_time is None:
            continue
        diagnostics[f"hop{hop}_first_accept_elapsed_ms"] = accept_time - source_time
        diagnostics[f"hop{hop}_segment_progress_ms"] = accept_time - previous_arrival
        diagnostics[f"hop{hop}_attribution"] = (
            "exact_single_source" if hop == 1 else "layer_inferred_parallel_relays"
        )

        upstream_bursts = [
            timestamp
            for event in message_events
            if event.get("event_type") == "ADVERTISE_BURST_STARTED"
            and event.get("burst_id") not in (None, "")
            and _transmit_hop(event) == hop
            and (timestamp := _timestamp(event)) is not None
            and timestamp <= accept_time
            and (
                hop != 1
                or event.get("node_id", event.get("device_id")) == source_node
            )
        ]
        diagnostics[f"hop{hop}_upstream_bursts_before_accept"] = len(
            upstream_bursts
        )

        if hop == 1 and upstream_bursts:
            selected_burst_time = max(upstream_bursts)
            diagnostics["source_attempt_index_to_hop1_accept"] = len(
                upstream_bursts
            )
            diagnostics["source_first_attempt_success"] = len(upstream_bursts) == 1
            diagnostics["source_retry_wait_ms"] = selected_burst_time - min(
                upstream_bursts
            )
            diagnostics["hop1_accept_after_source_burst_ms"] = (
                accept_time - selected_burst_time
            )
        previous_arrival = accept_time

    return diagnostics


def summarize_trial(
    trial_id: str,
    events: list[dict[str, Any]],
    manifest_record: dict[str, Any] | None = None,
) -> dict[str, Any]:
    record = manifest_record or {}
    session_id = record.get("session_id")
    normalized_events = []
    for event in events:
        if event.get("trial_id") != trial_id:
            continue
        if session_id is not None and event.get("session_id") != session_id:
            continue
        normalized = dict(event)
        if "message_key" in normalized:
            normalized["message_key"] = canonical_message_key(normalized["message_key"])
        if "state_identity" in normalized:
            normalized["state_identity"] = canonical_state_identity(
                normalized["state_identity"]
            )
        normalized["within_observation_window"] = event_within_observation_window(
            normalized,
            record,
        )
        normalized_events.append(normalized)
    events = deduplicate(normalized_events)
    metric_events = [
        event for event in events if event.get("within_observation_window") is True
    ]
    evidence = record.get("evidence", {})
    source_node = record.get("source_node_id", evidence.get("source_node_id"))
    destinations = set(record.get("destination_node_ids", evidence.get("destination_node_ids", [])))
    expected_hop = record.get("expected_hop_in", evidence.get("expected_hop_in"))
    expected_message_key = canonical_message_key(
        record.get("message_key", evidence.get("message_key"))
    )
    invalid_reasons = {str(item) for item in record.get("invalid_reasons", [])}
    invalid_reasons.update(research_event_integrity_errors(events, record))
    for key in (
        "source_node_id",
        "destination_node_ids",
        "expected_hop_in",
        "message_key",
    ):
        if key in record and key in evidence:
            record_value = canonical_message_key(record[key]) if key == "message_key" else record[key]
            evidence_value = canonical_message_key(evidence[key]) if key == "message_key" else evidence[key]
            if record_value != evidence_value:
                invalid_reasons.add("CONTROLLER_LOG_EVIDENCE_MISMATCH")

    try:
        observation_window_ms = int(record["observation_window_ms"])
    except (KeyError, TypeError, ValueError):
        observation_window_ms = 0
    try:
        clock_tolerance_ms = int(record["clock_tolerance_ms"])
    except (KeyError, TypeError, ValueError):
        clock_tolerance_ms = -1
    if observation_window_ms <= 0:
        invalid_reasons.add("OBSERVATION_WINDOW_INVALID")
    if clock_tolerance_ms < 0:
        invalid_reasons.add("CLOCK_TOLERANCE_INVALID")
    if not source_node:
        invalid_reasons.add("SOURCE_NODE_MISSING")
    if not destinations:
        invalid_reasons.add("DESTINATION_NODE_MISSING")
    if not expected_message_key:
        invalid_reasons.add("MESSAGE_KEY_MISSING")
    try:
        expected_hop_value = int(expected_hop)
    except (TypeError, ValueError):
        expected_hop_value = -1
        invalid_reasons.add("EXPECTED_HOP_INVALID")

    accepted = sum(
        event.get("event_type") == "BLE_PACKET_ACCEPTED" for event in metric_events
    )
    duplicates = sum(
        event.get("event_type") == "BLE_PACKET_DUPLICATE" for event in metric_events
    )
    denominator = accepted + duplicates
    burst_starts = {
        (event.get("node_id", event.get("device_id")), event.get("burst_id"))
        for event in metric_events
        if event.get("event_type") == "ADVERTISE_BURST_STARTED"
        and event.get("packet_type", "sos") == "sos"
        and event.get("burst_id") not in (None, "")
    }
    source_events = [
        event
        for event in metric_events
        if event.get("event_type") == "SOURCE_FIRST_ADVERTISE_STARTED"
        and event.get("node_id", event.get("device_id")) == source_node
        and event.get("message_key") == expected_message_key
    ]
    destination_events = [
        event
        for event in metric_events
        if event.get("event_type") == "DESTINATION_FIRST_VALID_RECEIVE"
        and event.get("node_id", event.get("device_id")) in destinations
        and event.get("message_key") == expected_message_key
        and _hop(event) == expected_hop_value
    ]
    if not source_events:
        invalid_reasons.add("SOURCE_EVENT_MISMATCH")
    if any(event.get("clock_sync_valid") is not True for event in source_events):
        invalid_reasons.add("CLOCK_SYNC_INVALID")
    if any(event.get("clock_sync_valid") is not True for event in destination_events):
        invalid_reasons.add("CLOCK_SYNC_INVALID")

    source_times = [timestamp for event in source_events if (timestamp := _timestamp(event)) is not None]
    destination_times = [
        timestamp
        for event in destination_events
        if (timestamp := _timestamp(event)) is not None
    ]
    latency_ms: int | None = None
    if source_times and destination_times:
        latency_ms = min(destination_times) - min(source_times)
        if latency_ms < 0:
            invalid_reasons.add("E2E_LATENCY_NEGATIVE")
            latency_ms = None
        elif latency_ms > observation_window_ms + clock_tolerance_ms:
            invalid_reasons.add("E2E_LATENCY_OUT_OF_RANGE")
            latency_ms = None

    controller_result = record.get("result")
    if controller_result == "SUCCESS" and not destination_events:
        invalid_reasons.add("DESTINATION_EVENT_MISMATCH")
    if controller_result == "SUCCESS" and latency_ms is None:
        invalid_reasons.add("CONTROLLER_LOG_EVIDENCE_MISMATCH")
    if controller_result == "FAILED_DELIVERY" and destination_events:
        invalid_reasons.add("CONTROLLER_LOG_EVIDENCE_MISMATCH")
    if "e2e_latency_ms" in evidence and evidence.get("e2e_latency_ms") != latency_ms:
        invalid_reasons.add("CONTROLLER_LOG_EVIDENCE_MISMATCH")

    diagnostics = latency_diagnostics(
        metric_events,
        source_node=source_node,
        destination_nodes=destinations,
        expected_hop=expected_hop_value,
        message_key=expected_message_key,
    )

    if invalid_reasons:
        result = "INVALID"
    elif controller_result in {"SUCCESS", "FAILED_DELIVERY"}:
        result = controller_result
    else:
        result = "SUCCESS" if destination_events else "FAILED_DELIVERY"
    return {
        "trial_id": trial_id,
        "mode": record.get("mode", next((event.get("mode") for event in events if event.get("mode")), None)),
        "hypothesis": record.get("hypothesis", next((event.get("hypothesis") for event in events if event.get("hypothesis")), None)),
        "result": result,
        "valid": result in {"SUCCESS", "FAILED_DELIVERY"},
        "invalid_reasons": ";".join(sorted(invalid_reasons)),
        "events_total": len(events),
        "events_in_window": len(metric_events),
        "events_outside_window": len(events) - len(metric_events),
        "metric_events_outside_window": sum(
            event.get("within_observation_window") is False
            and event.get("event_type") in METRIC_EVENT_TYPES
            for event in events
        ),
        "accepted": accepted,
        "duplicates": duplicates,
        "ldr": duplicates / denominator if denominator else None,
        "transmission_bursts": len(burst_starts),
        "e2e_latency_ms": latency_ms,
        **diagnostics,
    }


def aggregate(summaries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for summary in summaries:
        groups[(summary.get("mode") or "unknown", summary.get("hypothesis") or "unknown")].append(summary)
    output: list[dict[str, Any]] = []
    for (mode, hypothesis), rows in sorted(groups.items()):
        valid = [row for row in rows if row["valid"]]
        success = sum(row["result"] == "SUCCESS" for row in valid)
        accepted = sum(row["accepted"] for row in valid)
        duplicates = sum(row["duplicates"] for row in valid)
        ldr_denominator = accepted + duplicates
        overhead = sum(row["transmission_bursts"] for row in valid)
        latencies = [float(row["e2e_latency_ms"]) for row in valid if row["e2e_latency_ms"] is not None]
        stats = numeric_stats(latencies)
        output.append(
            {
                "mode": mode,
                "hypothesis": hypothesis,
                "valid_trials": len(valid),
                "success_trials": success,
                "dsr": success / len(valid) if valid else None,
                "ldr": duplicates / ldr_denominator if ldr_denominator else None,
                "transmission_overhead": overhead / len(valid) if valid else None,
                **{f"e2e_{key}": value for key, value in stats.items()},
            }
        )
    return output


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = sorted({key for row in rows for key in row})
    with path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def merge_directory(
    input_dir: Path,
    output_dir: Path,
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path and manifest_path.exists() else {"trials": {}}
    events = deduplicate(read_json_events(input_dir.rglob("*.jsonl")))
    manifest_session = manifest.get("session_id")
    if manifest_session:
        events = [event for event in events if event.get("session_id") == manifest_session]
    for event in events:
        record = (manifest.get("trials") or {}).get(str(event.get("trial_id")), {})
        if "message_key" in event:
            event["message_key"] = canonical_message_key(event["message_key"])
        if "state_identity" in event:
            event["state_identity"] = canonical_state_identity(
                event["state_identity"]
            )
        event["within_observation_window"] = event_within_observation_window(
            event,
            record,
        )
    by_trial: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        if event.get("trial_id"):
            by_trial[str(event["trial_id"])].append(event)
    trial_ids = sorted(set(by_trial) | set(manifest.get("trials", {})))
    summaries = []
    for trial_id in trial_ids:
        record = dict(manifest.get("trials", {}).get(trial_id) or {})
        if manifest_session:
            record.setdefault("session_id", manifest_session)
        summaries.append(summarize_trial(trial_id, by_trial[trial_id], record))
    aggregates = aggregate(summaries)
    invalid = [row for row in summaries if not row["valid"]]
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "events.json").write_text(json.dumps(events, indent=2, sort_keys=True), encoding="utf-8")
    _write_csv(output_dir / "events.csv", events)
    _write_csv(output_dir / "trial_summary.csv", summaries)
    _write_csv(output_dir / "aggregate_by_mode_hop.csv", aggregates)
    _write_csv(output_dir / "invalid_trials.csv", invalid)
    attempts = [
        {
            "trial_id": trial_id,
            "mode": record.get("mode"),
            "hypothesis": record.get("hypothesis"),
            "attempt": record.get("attempt"),
            "result": record.get("result"),
            "terminal": record.get("terminal"),
            "invalid_reasons": ";".join(record.get("invalid_reasons", [])),
        }
        for trial_id, record in sorted(manifest.get("trials", {}).items())
    ]
    _write_csv(output_dir / "attempt_summary.csv", attempts)
    write_analysis_workbook(
        output_dir / WORKBOOK_NAME,
        manifest=manifest,
        events=events,
        trial_summaries=summaries,
        aggregates=aggregates,
        attempts=attempts,
        invalid_trials=invalid,
    )
    return {
        "events": len(events),
        "trials": len(summaries),
        "invalid": len(invalid),
        "workbook": str(output_dir / WORKBOOK_NAME),
    }
