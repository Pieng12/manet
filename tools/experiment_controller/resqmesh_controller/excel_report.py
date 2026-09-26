from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

from openpyxl import Workbook
from openpyxl.formatting.rule import CellIsRule
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.table import Table, TableStyleInfo


WORKBOOK_NAME = "resqmesh_analysis.xlsx"
EXCEL_MAX_DATA_ROWS = 1_048_575

_HEADER_FILL = PatternFill("solid", fgColor="1F4E78")
_HEADER_FONT = Font(color="FFFFFF", bold=True)
_SUCCESS_FILL = PatternFill("solid", fgColor="C6EFCE")
_FAILURE_FILL = PatternFill("solid", fgColor="FFC7CE")

METRIC_DEFINITIONS = [
    {
        "metric": "Delivery Success Ratio",
        "abbreviation": "DSR",
        "unit": "ratio (0-1)",
        "level": "algorithm + hop",
        "formula": "SUCCESS / (SUCCESS + FAILED_DELIVERY)",
        "interpretation": "Higher is better",
        "validity_rule": "INVALID trials are excluded",
    },
    {
        "metric": "End-to-End Latency",
        "abbreviation": "E2E",
        "unit": "milliseconds",
        "level": "trial and algorithm + hop",
        "formula": "destination first valid receive - source first advertise started",
        "interpretation": "Lower is better",
        "validity_rule": "Requires synchronized clocks and matching message/hop",
    },
    {
        "metric": "Logical Duplicate Ratio",
        "abbreviation": "LDR",
        "unit": "ratio (0-1)",
        "level": "trial and algorithm + hop",
        "formula": "duplicates / (accepted + duplicates)",
        "interpretation": "Lower is better",
        "validity_rule": "Null when accepted + duplicates is zero",
    },
    {
        "metric": "Network-Wide Transmission Overhead",
        "abbreviation": "Overhead",
        "unit": "successful SOS bursts / valid trial",
        "level": "algorithm + hop",
        "formula": "sum(unique ADVERTISE_BURST_STARTED SOS bursts) / valid trials",
        "interpretation": "Lower is better for equal delivery performance",
        "validity_rule": "Counts successful starts, not requested advertisements",
    },
]


def _excel_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _ordered_fields(rows: list[dict[str, Any]], preferred: Iterable[str]) -> list[str]:
    available = {key for row in rows for key in row}
    ordered = [field for field in preferred if field in available]
    return ordered + sorted(available.difference(ordered))


def _safe_table_name(sheet_name: str, index: int) -> str:
    compact = "".join(character for character in sheet_name if character.isalnum())
    return f"ResQMesh{compact[:20]}{index}"


def _write_table(
    workbook: Workbook,
    sheet_name: str,
    rows: list[dict[str, Any]],
    preferred_fields: Iterable[str] = (),
) -> None:
    sheet = workbook.create_sheet(sheet_name)
    fields = _ordered_fields(rows, preferred_fields)
    if not fields:
        sheet.append(["status"])
        sheet.append(["No data"])
        fields = ["status"]
    else:
        sheet.append(fields)
        for row in rows:
            sheet.append([_excel_value(row.get(field)) for field in fields])

    for cell in sheet[1]:
        cell.fill = _HEADER_FILL
        cell.font = _HEADER_FONT
        cell.alignment = Alignment(horizontal="center", vertical="center")
    sheet.freeze_panes = "A2"
    if sheet.max_row >= 2:
        table = Table(
            displayName=_safe_table_name(sheet_name, len(workbook.worksheets)),
            ref=sheet.dimensions,
        )
        table.tableStyleInfo = TableStyleInfo(
            name="TableStyleMedium2",
            showFirstColumn=False,
            showLastColumn=False,
            showRowStripes=True,
            showColumnStripes=False,
        )
        sheet.add_table(table)

    for column_index, field in enumerate(fields, start=1):
        values = [str(field)] + [
            str(_excel_value(row.get(field)) or "") for row in rows[:250]
        ]
        width = min(max(max(map(len, values)) + 2, 11), 48)
        sheet.column_dimensions[get_column_letter(column_index)].width = width
        if field in {"dsr", "ldr"}:
            for cell in sheet[get_column_letter(column_index)][1:]:
                cell.number_format = "0.0000"
        elif field.endswith("_ms"):
            for cell in sheet[get_column_letter(column_index)][1:]:
                cell.number_format = "0"

    if "result" in fields:
        result_column = get_column_letter(fields.index("result") + 1)
        result_range = f"{result_column}2:{result_column}{sheet.max_row}"
        sheet.conditional_formatting.add(
            result_range,
            CellIsRule(operator="equal", formula=['"SUCCESS"'], fill=_SUCCESS_FILL),
        )
        sheet.conditional_formatting.add(
            result_range,
            CellIsRule(operator="notEqual", formula=['"SUCCESS"'], fill=_FAILURE_FILL),
        )


def _event_sheets(events: list[dict[str, Any]]) -> list[tuple[str, list[dict[str, Any]]]]:
    if not events:
        return [("All Events", [])]
    chunks = []
    for start in range(0, len(events), EXCEL_MAX_DATA_ROWS):
        number = (start // EXCEL_MAX_DATA_ROWS) + 1
        name = "All Events" if number == 1 else f"All Events {number}"
        chunks.append((name, events[start : start + EXCEL_MAX_DATA_ROWS]))
    return chunks


def write_analysis_workbook(
    output_path: Path,
    *,
    manifest: dict[str, Any],
    events: list[dict[str, Any]],
    trial_summaries: list[dict[str, Any]],
    aggregates: list[dict[str, Any]],
    attempts: list[dict[str, Any]],
    invalid_trials: list[dict[str, Any]],
) -> Path:
    workbook = Workbook()
    workbook.remove(workbook.active)

    metadata = [
        {"field": "session_id", "value": manifest.get("session_id")},
        {"field": "config_fingerprint", "value": manifest.get("config_fingerprint")},
        {"field": "protocol_version", "value": manifest.get("protocol_version")},
        {"field": "protocol_epoch_id", "value": manifest.get("epoch_id")},
        {"field": "algorithms", "value": ", ".join(sorted({str(row.get("mode")) for row in trial_summaries if row.get("mode")}))},
        {"field": "trial_count", "value": len(trial_summaries)},
        {"field": "event_count", "value": len(events)},
        {"field": "invalid_trial_count", "value": len(invalid_trials)},
    ]
    _write_table(workbook, "Overview", metadata, ("field", "value"))
    _write_table(
        workbook,
        "Metric Definitions",
        METRIC_DEFINITIONS,
        ("metric", "abbreviation", "unit", "level", "formula", "interpretation", "validity_rule"),
    )
    _write_table(
        workbook,
        "Algorithm Summary",
        aggregates,
        (
            "mode",
            "hypothesis",
            "valid_trials",
            "success_trials",
            "dsr",
            "e2e_count",
            "e2e_min",
            "e2e_max",
            "e2e_mean",
            "e2e_median",
            "e2e_sample_stddev",
            "e2e_q1",
            "e2e_q3",
            "e2e_iqr",
            "ldr",
            "transmission_overhead",
        ),
    )
    trial_rows = [
        {
            **row,
            "algorithm": row.get("mode"),
            "delivery_success": 1 if row.get("result") == "SUCCESS" else 0,
        }
        for row in trial_summaries
    ]
    _write_table(
        workbook,
        "Trial Metrics",
        trial_rows,
        (
            "trial_id",
            "algorithm",
            "mode",
            "hypothesis",
            "result",
            "valid",
            "delivery_success",
            "e2e_latency_ms",
            "events_total",
            "events_in_window",
            "events_outside_window",
            "metric_events_outside_window",
            "accepted",
            "duplicates",
            "ldr",
            "transmission_bursts",
            "invalid_reasons",
        ),
    )
    _write_table(
        workbook,
        "Event Type Counts",
        [
            {"event_type": event_type, "count": count}
            for event_type, count in sorted(
                Counter(str(event.get("event_type") or "UNKNOWN") for event in events).items()
            )
        ],
        ("event_type", "count"),
    )
    _write_table(
        workbook,
        "Attempts",
        attempts,
        ("trial_id", "mode", "hypothesis", "attempt", "result", "terminal", "invalid_reasons"),
    )
    _write_table(
        workbook,
        "Invalid Trials",
        invalid_trials,
        ("trial_id", "mode", "hypothesis", "result", "invalid_reasons"),
    )
    manifest_metadata = [
        {"field": key, "value": value}
        for key, value in sorted(manifest.items())
        if key != "trials"
    ]
    _write_table(
        workbook,
        "Manifest Metadata",
        manifest_metadata,
        ("field", "value"),
    )
    manifest_trials = [
        {"trial_id": trial_id, **record}
        for trial_id, record in sorted((manifest.get("trials") or {}).items())
    ]
    _write_table(
        workbook,
        "Manifest Trials",
        manifest_trials,
        ("trial_id", "device_trial_id", "mode", "hypothesis", "attempt", "result", "terminal"),
    )
    for name, rows in _event_sheets(events):
        _write_table(
            workbook,
            name,
            rows,
            (
                "session_id",
                "trial_id",
                "mode",
                "hypothesis",
                "node_id",
                "role",
                "event_type",
                "event_sequence",
                "within_observation_window",
                "timestamp_ms",
                "event_timestamp_ms",
                "message_key",
                "state_identity",
                "observation_id",
                "burst_id",
                "packet_type",
                "status",
                "hop_in",
                "hop_out",
                "rssi",
            ),
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(output_path)
    return output_path
