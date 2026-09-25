from __future__ import annotations

import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


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
    if event.get("event_key"):
        return node, "event_key", event["event_key"]
    if event.get("observation_id") and event.get("event_type") in {
        "BLE_PACKET_RECEIVED",
        "ACK_RECEIVED",
    }:
        return node, event["event_type"], event["observation_id"]
    if event.get("burst_id") and event.get("event_type"):
        return node, event["event_type"], event["burst_id"]
    return (
        node,
        event.get("trial_id"),
        event.get("event_type"),
        event.get("message_key"),
        event.get("timestamp_ms"),
        event.get("monotonic_ms", event.get("elapsed_realtime_ms")),
    )


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
    offset = event.get("clock_offset_ms", 0) if event.get("clock_sync_valid") is True else 0
    return int(round(float(value) + float(offset)))


def summarize_trial(
    trial_id: str,
    events: list[dict[str, Any]],
    manifest_record: dict[str, Any] | None = None,
) -> dict[str, Any]:
    record = manifest_record or {}
    result = record.get("result")
    if result is None:
        result = "SUCCESS" if any(event.get("event_type") == "DESTINATION_FIRST_VALID_RECEIVE" for event in events) else "FAILED_DELIVERY"
    accepted = sum(event.get("event_type") == "BLE_PACKET_ACCEPTED" for event in events)
    duplicates = sum(event.get("event_type") == "BLE_PACKET_DUPLICATE" for event in events)
    denominator = accepted + duplicates
    burst_starts = {
        (event.get("node_id", event.get("device_id")), event.get("burst_id"))
        for event in events
        if event.get("event_type") == "ADVERTISE_BURST_STARTED"
        and event.get("packet_type", "sos") == "sos"
    }
    sources: dict[str, int] = {}
    latencies: list[int] = []
    for event in events:
        key = event.get("message_key")
        timestamp = _timestamp(event)
        if not key or timestamp is None:
            continue
        if event.get("event_type") == "SOURCE_FIRST_ADVERTISE_STARTED":
            sources.setdefault(key, timestamp)
        elif event.get("event_type") == "DESTINATION_FIRST_VALID_RECEIVE":
            detail = event.get("detail", {})
            sync_valid = event.get("clock_sync_valid") is True or (
                isinstance(detail, dict) and detail.get("clock_sync_valid") is True
            )
            if sync_valid and key in sources and timestamp >= sources[key]:
                latencies.append(timestamp - sources[key])
    invalid_reasons = record.get("invalid_reasons", [])
    return {
        "trial_id": trial_id,
        "mode": record.get("mode", next((event.get("mode") for event in events if event.get("mode")), None)),
        "hypothesis": record.get("hypothesis", next((event.get("hypothesis") for event in events if event.get("hypothesis")), None)),
        "result": result,
        "valid": result in {"SUCCESS", "FAILED_DELIVERY"},
        "invalid_reasons": ";".join(str(item) for item in invalid_reasons),
        "accepted": accepted,
        "duplicates": duplicates,
        "ldr": duplicates / denominator if denominator else None,
        "transmission_bursts": len(burst_starts),
        "e2e_latency_ms": min(latencies) if latencies else None,
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


def merge_directory(input_dir: Path, output_dir: Path, manifest_path: Path | None = None) -> dict[str, int]:
    events = deduplicate(read_json_events(input_dir.rglob("*.jsonl")))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path and manifest_path.exists() else {"trials": {}}
    by_trial: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        if event.get("trial_id"):
            by_trial[str(event["trial_id"])].append(event)
    trial_ids = sorted(set(by_trial) | set(manifest.get("trials", {})))
    summaries = [summarize_trial(trial_id, by_trial[trial_id], manifest.get("trials", {}).get(trial_id)) for trial_id in trial_ids]
    aggregates = aggregate(summaries)
    invalid = [row for row in summaries if not row["valid"]]
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "events.json").write_text(json.dumps(events, indent=2, sort_keys=True), encoding="utf-8")
    _write_csv(output_dir / "events.csv", events)
    _write_csv(output_dir / "trial_summary.csv", summaries)
    _write_csv(output_dir / "aggregate_by_mode_hop.csv", aggregates)
    _write_csv(output_dir / "invalid_trials.csv", invalid)
    return {"events": len(events), "trials": len(summaries), "invalid": len(invalid)}
