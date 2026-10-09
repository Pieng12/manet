"""Additive recovery evidence; the four network metric formulas are untouched."""
import math
import statistics

from .neighbor_testbed import RECOVERY_VERSION, scenario_parameters, testbed


def recovery_metrics(events, record):
    from .neighbor_experiment import flatten, stable_id, _recovery_timing
    from .log_merge import _timestamp

    design = testbed(record)
    parameters = scenario_parameters(record, record["hypothesis"])
    scope = stable_id(record["device_trial_id"])
    start, end = record.get("observation_started_at_ms"), record.get("observation_ended_at_ms")
    samples = [flatten(e) for e in events]
    samples = [e for e in samples if e.get("session_id") == record.get("session_id")
               and e.get("trial_id") == record["trial_id"] and (e.get("scope") == scope
               or e.get("scope") is None and e.get("event_type") == "SOS_CREATED" and e.get("node_id") == design.source)]
    keys = {e.get("message_key") for e in samples if e.get("event_type") == "SOS_CREATED"
            and e.get("node_id") == design.source and e.get("message_key")}
    key = record.get("message_key")
    if key is None and len(keys) == 1:
        key = next(iter(keys))
    results = []
    for node in design.targets:
        eligible = node in parameters["inactive_node_ids"]
        row = {"receiver": node, "recovery_eligible": eligible,
               "recovery_status": "TIMING_UNVERIFIED" if eligible else "NOT_APPLICABLE",
               "recovery_delay_ms": None, "recovery_received": False,
               "recovery_on_confirmed_at_ms": None, "recovery_on_monotonic_ms": None,
               "first_rx_monotonic_ms": None, "recovery_first_rx_at_ms": None,
               "recovery_clock_domain": None, "recovery_local_boot_id": None,
               "recovery_time_basis": "unverified", "recovery_followup_ms": None,
               "recovery_followup_basis": "corrected_wall_window_boundary",
               "recovery_observation_id": None,
               "recovery_unavailable_reason": "ON_EVENT_MISSING" if eligible else "NOT_PERTURBED"}
        results.append(row)
        if not eligible:
            continue
        requests = [p for p in record.get("participation", []) if p.get("node") == node
                    and p.get("enabled") is True and p.get("response", {}).get("confirmed_enabled") is True]
        on = [e for e in samples if e.get("node_id") == node
              and e.get("event_type") == "NODE_PARTICIPATION_CHANGED"
              and e.get("confirmed_enabled") is True and e.get("rx_enabled") is True
              and e.get("tx_enabled") is True and e.get("scanner_registered") is True]
        if len(on) != 1 or len(requests) != 1:
            row["recovery_unavailable_reason"] = "ON_EVENT_MISSING_OR_AMBIGUOUS"
            continue
        activation = on[0]
        boot, domain, mono = (activation.get(k) for k in ("local_boot_id", "clock_domain", "monotonic_ms"))
        on_at = _timestamp(activation)
        row.update(recovery_on_confirmed_at_ms=on_at, recovery_on_monotonic_ms=mono,
                   recovery_local_boot_id=boot, recovery_clock_domain=domain)
        if on_at is not None and end is not None:
            row["recovery_followup_ms"] = max(0, end-on_at)
        if key not in keys or len(keys) != 1:
            row["recovery_unavailable_reason"] = "SOS_IDENTITY_UNVERIFIED"
            continue
        rx = [e for e in samples if e.get("node_id") == node and e.get("event_type") == "DATA_RECEIVED"
              and e.get("message_key") == key and key in keys
              and e.get("transmitter_id") in design.adjacency(node)
              and all(e.get(k) is not None for k in ("boot_id", "transmission_sequence"))
              and _timestamp(e) is not None and start is not None and end is not None
              and start <= _timestamp(e) < end]
        if any(on_at is not None and _timestamp(e) < on_at for e in rx):
            row["recovery_unavailable_reason"] = "RX_BEFORE_ON"
            continue
        rx.sort(key=lambda e: (_timestamp(e), e.get("event_sequence", 0)))
        if rx:
            first = rx[0]
            row.update(_recovery_timing(samples, record, first))
            row.update(recovery_received=True, recovery_first_rx_at_ms=_timestamp(first),
                       recovery_observation_id=": ".join(str(first.get(k)) for k in
                           ("scope", "transmitter_id", "boot_id", "transmission_sequence")))
            if row["recovery_delay_ms"] is not None:
                row["recovery_status"] = "RECOVERED"
        elif key not in keys or len(keys) != 1:
            row["recovery_unavailable_reason"] = "SOS_IDENTITY_UNVERIFIED"
        elif (domain != "esp_boot_millis" or type(boot) is not int or boot <= 0
              or type(mono) not in (int, float) or not math.isfinite(mono) or mono < 0
              or requests[0]["response"].get("local_boot_id") != boot
              or on_at is None or start is None or end is None or not start <= on_at < end):
            row["recovery_unavailable_reason"] = "ON_CLOCK_UNVERIFIED"
        else:
            row.update(recovery_status="NOT_RECOVERED_WITHIN_WINDOW",
                       recovery_unavailable_reason="NO_RX_IN_WINDOW")
    eligible = [r for r in results if r["recovery_eligible"]]
    values = [r["recovery_delay_ms"] for r in eligible if r["recovery_status"] == "RECOVERED"]
    return {"recovery_measurement_version": RECOVERY_VERSION, "recovery_receivers": results,
            "recovery_eligible_targets": len(eligible),
            "recovery_received_targets": sum(r["recovery_received"] for r in eligible),
            "recovery_defined_targets": len(values),
            "recovery_unreceived_targets": sum(r["recovery_status"] == "NOT_RECOVERED_WITHIN_WINDOW" for r in eligible),
            "recovery_unverified_targets": sum(r["recovery_status"] == "TIMING_UNVERIFIED" for r in eligible),
            "recovery_mean_ms": statistics.mean(values) if values else None}
