"""Additive descriptive reporting. No scheduling or protocol decisions live here."""
from __future__ import annotations

import math
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path

METRICS = {
    "dsr_percent": ("DSR rata-rata per trial", "%"),
    "e2e_mean_ms": ("Delay rata-rata trial dengan RX", "ms"),
    "ldr_percent": ("LDR rata-rata per trial", "%"),
    "network_overhead": ("Overhead rata-rata per trial", "burst logis/trial"),
    "data_tx": ("DATA rata-rata per trial", "burst logis/trial"),
    "control_tx": ("STATUS rata-rata per trial", "burst logis/trial"),
    "setup_control_tx": ("STATUS persiapan rata-rata per trial", "burst logis/trial"),
    "setup_plus_window_tx": ("Persiapan + window rata-rata per trial", "burst logis/trial"),
}


def descriptive(values):
    values = [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)]
    return {"defined_trials": len(values), "mean": statistics.mean(values) if values else None,
            "median": statistics.median(values) if values else None,
            "sample_sd": statistics.stdev(values) if len(values) >= 2 else None,
            "min": min(values) if values else None, "max": max(values) if values else None}


def aggregate(rows, receivers, scenarios, methods):
    summaries, stats = [], []
    for scenario in scenarios:
        for method in methods:
            group = [r for r in rows if r["scenario"] == scenario and r["method"] == method]
            valid = [r for r in group if r["valid"]]
            m, u, r = (sum(t.get(k, 0) or 0 for t in valid) for k in ("M", "U", "R"))
            delays = [p["e2e_latency_ms"] for p in receivers if p["scenario"] == scenario
                      and p["method"] == method and p["valid"] and p.get("e2e_latency_ms") is not None]
            summary = {"method": method, "scenario": scenario,
                       "analysis_group": "utama" if scenario == "S0_MAIN" else "pendukung",
                       "valid_trials": len(valid), "invalid_trials": sum(t["result"] == "INVALID" for t in group),
                       "failed_delivery_trials": sum(t["result"] == "FAILED_DELIVERY" for t in valid),
                       "M": m, "N": 5, "U": u, "R": r,
                       "dsr_percent": 100*u/(m*5) if m else None,
                       "ldr_percent": 100*(r-u)/r if r else None,
                       "successful_pairs": sum(t.get("successful_pairs", 0) or 0 for t in valid),
                       "defined_delay_pairs": len(delays),
                       "e2e_mean_ms": statistics.mean(delays) if delays else None,
                       "aggregate_basis": "DSR/LDR: rasio jumlah; E2E: pasangan sukses, bukan rata-rata trial"}
            for k in ("data_tx", "control_tx", "network_overhead", "setup_control_tx", "setup_plus_window_tx"):
                summary[k] = sum(t.get(k, 0) or 0 for t in valid)
            for metric, (label, unit) in METRICS.items():
                result = descriptive([t.get(metric) for t in valid])
                stats.append({"method": method, "scenario": scenario, "metric": metric,
                              "label": label, "unit": unit, "valid_trials": len(valid),
                              "invalid_trials": summary["invalid_trials"], **result})
                summary[f"{metric}_trial_mean"] = result["mean"]
            summaries.append(summary)
    return summaries, stats


def phy_evidence(radio):
    radio = radio or {}
    # Older configured_mode is only filled after successful configuration, not from requested PHY.
    accepted = radio.get("api_configuration_accepted")
    if accepted is None and radio.get("configured_mode") is not None:
        accepted = radio.get("ready") is True and radio.get("last_error") in (None, 0)
    verified = radio.get("on_air_coding_verified") is True
    coding = radio.get("coding_actual", "UNKNOWN")
    if not verified or coding not in ("S2", "S8"):
        coding = "UNKNOWN"
    return {"phy_requested": radio.get("requested_mode"), "api_configuration_accepted": accepted,
            "coding_selection_support": radio.get("coding_selection_support", "UNKNOWN"),
            "coding_requested": radio.get("coding_requested", "UNKNOWN"),
            "s8_requirement_accepted": radio.get("s8_requirement_accepted"),
            "coding_actual": coding, "on_air_coding_status": "VERIFIED" if coding != "UNKNOWN" else "UNVERIFIED",
            "claim_limit": "LE Coded tidak otomatis membuktikan S=8 atau 125 kbps"}


def mechanism_counts(events, records):
    from .neighbor_experiment import flatten, stable_id
    mapping = {"INITIAL_FORWARD_PENDING": "initial_pending", "INITIAL_FORWARD_STARTED": "initial_started",
               "INITIAL_FORWARD_FAILED": "initial_failed", "NEIGHBOR_ALLOW_MISSING": "allow_missing",
               "NEIGHBOR_ALLOW_UNKNOWN": "allow_unknown", "NEIGHBOR_SUPPRESSED_ALL_HAVE": "suppressed_all_have",
               "REPAIR_NEEDED": "repair_performed", "REPAIR_DEFERRED_COOLDOWN": "repair_deferred_cooldown",
               "NEIGHBOR_STATUS_EXPIRED": "status_expired"}
    rows = []
    for trial_id, record in records.items():
        counts = dict.fromkeys(mapping.values(), 0)
        seen = set()
        for raw in events:
            e = flatten(raw)
            if e.get("trial_id") != trial_id or e.get("scope") != stable_id(record["device_trial_id"]):
                continue
            kind = e.get("event_type")
            if kind == "NEIGHBOR_TX_ALLOWED":
                kind = {"INITIAL_FORWARD_PENDING": "INITIAL_FORWARD_PENDING", "FRESH_MISSING": "NEIGHBOR_ALLOW_MISSING",
                        "UNKNOWN_OR_NO_NEIGHBORS": "NEIGHBOR_ALLOW_UNKNOWN"}.get(e.get("reason"))
            elif kind == "NEIGHBOR_TX_SUPPRESSED" and e.get("reason") == "ALL_OBSERVED_HAVE":
                kind = "NEIGHBOR_SUPPRESSED_ALL_HAVE"
            if kind not in mapping:
                continue
            identity = (e.get("node_id"), e.get("event_id", e.get("id")), e.get("event_sequence"),
                        e.get("event_type"), e.get("monotonic_ms", e.get("timestamp_ms")), e.get("detail_json"))
            if identity in seen:
                continue
            seen.add(identity)
            counts[mapping[kind]] += 1
        rows.append({"trial_id": trial_id, "method": record["mode"], "scenario": record["hypothesis"],
                     "basis": "Event seluruh trial, termasuk sebelum window; frekuensi bukan metrik RF", **counts})
    return rows


def write_charts(output, summaries, stats, scenarios, methods, synthetic=False):
    """Openable SVGs with missing values kept visibly missing, not converted to bars of zero."""
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    paths = []
    for scenario in scenarios:
        group = {s["method"]: s for s in summaries if s["scenario"] == scenario}
        for metric in (*tuple(METRICS)[:4], "composition"):
            label, unit = METRICS.get(metric, ("Komposisi DATA dan STATUS dalam window", "burst logis/trial"))
            root = ET.Element("svg", xmlns="http://www.w3.org/2000/svg", width="1160", height="440", viewBox="0 0 1160 440")
            ET.SubElement(root, "rect", width="1160", height="440", fill="white")
            def text(x, y, value, size=15):
                ET.SubElement(root, "text", x=str(x), y=str(y), fill="#222222",
                              style=f"font-family:Arial,sans-serif;font-size:{size}px").text = str(value)
            text(20, 30, f"{'DATA SINTETIS | ' if synthetic else ''}{scenario}: {label} ({unit})", 20)
            text(20, 55, "Trial valid termasuk FAILED_DELIVERY; INVALID dikecualikan. Nilai kosong bukan nol.")
            if metric == "composition":
                text(20, 80, "Biru: DATA | Hijau: STATUS. STATUS persiapan tidak masuk grafik window.")
            values = []
            for method in methods:
                s = group.get(method, {})
                value = s.get("network_overhead_trial_mean" if metric == "composition" else f"{metric}_trial_mean")
                values.append(value)
            maximum = max([v for v in values if v is not None] or [1]) or 1
            for i, method in enumerate(methods):
                x, base = 25 + i*285, 300
                s, value = group.get(method, {}), values[i]
                if value is None:
                    text(x, base-20, "Tidak ada nilai terdefinisi")
                else:
                    components = [(s.get("data_tx_trial_mean", 0), "#2675a9"), (s.get("control_tx_trial_mean", 0), "#29956b")] if metric == "composition" else [(value, "#2675a9")]
                    for v, color in components:
                        h = (v or 0)/maximum*185
                        ET.SubElement(root, "rect", x=str(x), y=str(base-h), width="210", height=str(h), fill=color)
                        base -= h
                    text(x, max(100, base-10), f"{value:.3f}")
                text(x, 325, method, 13)
                text(x, 350, f"Valid: {s.get('valid_trials', 0)}; invalid: {s.get('invalid_trials', 0)}", 13)
                if metric == "e2e_mean_ms":
                    dsr = s.get("dsr_percent")
                    text(x, 375, f"Pasangan sukses: {s.get('successful_pairs', 0)}; DSR agregat: {'kosong' if dsr is None else f'{dsr:.1f}%'}", 12)
                    text(x, 398, "Delay trial tanpa penerimaan: kosong", 12)
                else:
                    n = next((v["defined_trials"] for v in stats if v["scenario"] == scenario and v["method"] == method and v["metric"] == metric), None)
                    if n is not None:
                        text(x, 375, f"Trial dengan nilai terdefinisi: {n}", 13)
            path = output/f"{scenario}-{metric}.svg"
            ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
            paths.append(str(path))
    return paths
