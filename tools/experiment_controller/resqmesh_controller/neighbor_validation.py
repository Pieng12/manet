"""Evidence checks, not a certificate that a physical experiment was performed."""
from __future__ import annotations

import json
from pathlib import Path


def _positive_counter(value):
    return type(value) is int and value > 0


def _expiry_evidence(samples, at):
    def order(e):
        counter = e.get("event_sequence", e.get("id"))
        return at(e), counter if _positive_counter(counter) else 0

    cases = []
    for expired in samples:
        if expired.get("event_type") != "NEIGHBOR_STATUS_EXPIRED":
            continue
        node, peer = expired.get("node_id"), expired.get("transmitter_id")
        case = {"node_id": node, "transmitter_id": peer, "expired_at": at(expired),
                "event_sequence": expired.get("event_sequence"), "id": expired.get("id"),
                "result": "INCONCLUSIVE", "observed_states": []}
        cases.append(case)
        if node is None or peer is None or at(expired) <= 0:
            continue
        # Keep observer, peer and expiry episode together; a different peer's refresh is irrelevant.
        stream = [e for e in samples if e.get("node_id") == node and order(e) > order(expired)]
        boundaries = [order(e) for e in stream if e.get("transmitter_id") == peer
                      and e.get("event_type") in {"NEIGHBOR_STATUS_UPDATED", "NEIGHBOR_STATUS_EXPIRED"}]
        end = min(boundaries) if boundaries else None
        decisions = [e for e in stream if e.get("event_type") in {"NEIGHBOR_TX_ALLOWED", "NEIGHBOR_TX_SUPPRESSED"}
                     and (end is None or order(e) < end)]
        states = [e.get("neighbor_knowledge", {}).get(str(peer)) for e in decisions]
        case["observed_states"] = states
        if any(s in {"HAVE", "MISSING"} for s in states):
            case["result"] = "FAIL"
        elif states and all(s == "UNKNOWN" for s in states):
            case["result"] = "PASS"
    return cases


def validate_logs(events, manifest):
    from .neighbor_experiment import SOURCE, TARGETS, flatten, stable_id, summarize_network
    results = []
    synthetic = manifest.get("synthetic_data") is True
    for trial_id, record in manifest.get("trials", {}).items():
        scope = stable_id(record["device_trial_id"])
        samples = [flatten(e) for e in events]
        samples = [e for e in samples if e.get("session_id") == manifest.get("session_id")
                   and e.get("trial_id") == trial_id and e.get("scope") in (None, scope)]
        def at(e):
            return e.get("monotonic_ms", e.get("elapsed_realtime_ms", e.get("timestamp_ms", 0))) or 0
        def later(e, kind):
            return [v for v in samples if v.get("node_id") == e.get("node_id")
                    and v.get("event_type") in kind and at(v) > at(e)]
        def put(check, good=False, bad=False, evidence=None):
            results.append({"trial_id": trial_id, "method": record["mode"], "scenario": record["hypothesis"],
                            "check": check, "result": "FAIL" if bad else "PASS" if good else "INCONCLUSIVE",
                            "evidence": evidence or "Bukti wajib belum tersedia / kasus belum teramati",
                            "evidence_origin": "SYNTHETIC_FIXTURE_NOT_HARDWARE" if synthetic else "RECORDED_LOG_NOT_INDEPENDENT_RF_VERIFICATION"})
        if record["mode"] == "trickle_neighbor_status":
            decisions = [e for e in samples if e.get("event_type") in {"NEIGHBOR_TX_ALLOWED", "NEIGHBOR_TX_SUPPRESSED"}
                         and all(isinstance(e.get(k), int) for k in ("have_count", "missing_count", "unknown_count"))]
            bad_decisions = []
            for e in decisions:
                h, m, u = (e[k] for k in ("have_count", "missing_count", "unknown_count"))
                reason = e.get("reason")
                allowed = e["event_type"] == "NEIGHBOR_TX_ALLOWED"
                bad = min(h, m, u) < 0 or (not allowed and (reason != "ALL_OBSERVED_HAVE" or h == 0 or m > 0 or u > 0))
                bad = bad or (allowed and reason == "ALL_OBSERVED_HAVE") or (reason == "FRESH_MISSING" and (not allowed or m == 0))
                bad = bad or (reason == "UNKNOWN_OR_NO_NEIGHBORS" and (not allowed or m > 0 or (u == 0 and h > 0)))
                if bad:
                    bad_decisions.append(e)
            put("NEIGHBOR_DECISION_CONSISTENCY", bool(decisions) and not bad_decisions, bool(bad_decisions))
            a = [e for e in samples if e.get("node_id") == TARGETS[0] and e.get("event_type") in {"NEIGHBOR_TX_ALLOWED", "NEIGHBOR_TX_SUPPRESSED"}]
            mixed = [e for e in a if e.get("neighbor_knowledge", {}).get(str(stable_id(TARGETS[2]))) == "HAVE"
                     and e.get("neighbor_knowledge", {}).get(str(stable_id(TARGETS[3]))) == "MISSING"]
            put("A_C_HAVE_D_MISSING", any(e.get("reason") == "FRESH_MISSING" and e["event_type"] == "NEIGHBOR_TX_ALLOWED" for e in mixed),
                any(e["event_type"] == "NEIGHBOR_TX_SUPPRESSED" for e in mixed))
            all_have = [e for e in samples if e.get("reason") == "ALL_OBSERVED_HAVE"
                        and e.get("event_type") == "NEIGHBOR_TX_SUPPRESSED" and (e.get("have_count") or 0) > 0
                        and e.get("missing_count") == 0 and e.get("unknown_count") == 0]
            suppression_contradiction = any(e.get("event_type") == "NEIGHBOR_TX_ALLOWED" and e.get("reason") == "ALL_OBSERVED_HAVE" for e in samples)
            put("ALL_HAVE_SUPPRESSION_STATUS_CONTINUES", any(later(e, {"STATUS_BURST_STARTED"}) for e in all_have), suppression_contradiction)
            expiry_cases = _expiry_evidence(samples, at)
            put("EXPIRED_STATUS_UNKNOWN", bool(expiry_cases) and all(e["result"] == "PASS" for e in expiry_cases),
                any(e["result"] == "FAIL" for e in expiry_cases),
                json.dumps({"expiry_episodes": expiry_cases}, ensure_ascii=False))
            empty = [e for e in samples if e.get("event_type") == "STATUS_RECEIVED"
                     and e.get("inventory_count") == 0 and e.get("snapshot_complete") is True]
            put("EMPTY_STATUS_DISCOVERY_REPAIR", any(
                all(any(v.get("transport_burst_id") == e.get("transport_burst_id")
                        and v.get("transmitter_id") == e.get("transmitter_id") and at(v) >= at(e)
                        for v in samples if v.get("node_id") == e.get("node_id") and v.get("event_type") == kind)
                    for kind in ("NEIGHBOR_DISCOVERED", "REPAIR_NEEDED"))
                for e in empty if e.get("transport_burst_id") is not None))
            failures = [e for e in samples if e.get("event_type") == "INITIAL_FORWARD_FAILED"]
            put("INITIAL_FAILURE_REMAINS_PENDING", bool(failures) and all(e.get("first_forward_pending") is True for e in failures),
                any(e.get("first_forward_pending") is False for e in failures))
        for outcome in ("ENDED", "FAILED", "CANCELLED"):
            bursts = [e for e in samples if e.get("event_type") in {f"DATA_BURST_{outcome}", f"STATUS_BURST_{outcome}"}]
            checks = [v for e in bursts for v in samples if v.get("node_id") == e.get("node_id")
                      and v.get("event_type") == "SCANNER_RECOVERY_CHECK" and v.get("burst_outcome") == outcome
                      and v.get("transport_burst_id") == e.get("transport_burst_id") and at(v) >= at(e)]
            good = bool(bursts) and all(any(v.get("node_id") == e.get("node_id")
                      and v.get("transport_burst_id") == e.get("transport_burst_id") and v.get("rx_enabled") is True
                      and v.get("scanner_registered") is True and later(v, {"DATA_RECEIVED", "STATUS_RECEIVED"}) for v in checks) for e in bursts)
            put(f"SCANNER_RECOVERY_{outcome}", good, any(v.get("rx_enabled") is True and v.get("scanner_registered") is False for v in checks),
                "Perlu status API scanner dan RX berikutnya pada node sama; registrasi saja bukan bukti RF pulih")
        scenario = record["hypothesis"]
        if scenario in {"S1_DELAYED_RX", "S2_LATE_JOIN"}:
            node, kind = (TARGETS[3], "RX_PARTICIPATION_CHANGED") if scenario == "S1_DELAYED_RX" else (TARGETS[4], "NODE_PARTICIPATION_CHANGED")
            changes = [e for e in samples if e.get("node_id") == node and e.get("event_type") == kind]
            off = [e for e in changes if e.get("confirmed_enabled") is False and e.get("rx_enabled") is False and e.get("scanner_registered") is False
                   and (scenario == "S1_DELAYED_RX" or e.get("tx_enabled") is False)]
            on = [e for e in changes if e.get("confirmed_enabled") is True and e.get("rx_enabled") is True
                  and (scenario == "S1_DELAYED_RX" or e.get("tx_enabled") is True)]
            contradiction = any(e.get("confirmed_enabled") is False and (e.get("rx_enabled") is True or
                                (scenario == "S2_LATE_JOIN" and e.get("tx_enabled") is True)) for e in changes)
            put("ACTUAL_PARTICIPATION_OFF_ON", any(at(a) < at(b) for a in off for b in on), contradiction,
                "Perlu perubahan hardware terkonfirmasi, OFF lalu ON pada D (S1) atau E (S2)")
        missing, gaps, missing_sequences, conflicts = [], [], [], []
        for node in (SOURCE, *TARGETS):
            node_events = [e for e in samples if e.get("node_id") == node]
            if not node_events:
                missing.append(node)
            # Only ESP serial logs promise contiguous event_sequence; Android DB IDs do not.
            if node not in TARGETS:
                continue
            valid = bool(node_events) and all(_positive_counter(e.get("event_sequence")) for e in node_events)
            if not valid:
                missing_sequences.append(node)
            by_sequence = {}
            for e in node_events:
                counter = e.get("event_sequence")
                if not _positive_counter(counter):
                    continue
                if counter in by_sequence and by_sequence[counter] != e:
                    if node not in conflicts:
                        conflicts.append(node)
                by_sequence[counter] = e
            seq = sorted(by_sequence)
            if valid and any(b != a+1 for a, b in zip(seq, seq[1:])):
                gaps.append(node)
        # Contiguous interior events alone cannot prove start/end of an archive were retained.
        complete = not missing and not gaps and not missing_sequences and not conflicts and all(all(any(e.get("node_id") == n and e.get("event_type") == marker for e in samples)
                   for marker in ("TRIAL_WINDOW_STARTED", "TRIAL_WINDOW_ENDED")) for n in (SOURCE, *TARGETS))
        put("LOG_COMPLETENESS", complete, bool(gaps or conflicts),
            f"Node tanpa log: {missing}; counter ESP hilang/tidak valid: {missing_sequences}; "
            f"gap event_sequence: {gaps}; counter berkonflik: {conflicts}; perlu marker awal/akhir keenam node; "
            "Android tidak memiliki kontrak event_sequence kontigu")
        expected = record.get("evidence", {})
        actual = None
        if all(record.get(k) is not None for k in ("observation_started_at_ms", "observation_ended_at_ms")):
            actual = summarize_network(samples, {**record, "trial_id": trial_id, "session_id": manifest.get("session_id"), "scope": scope})
        keys = ("M", "N", "U", "R", "data_tx", "control_tx", "network_overhead", "dsr_percent", "ldr_percent", "e2e_mean_ms")
        comparable = actual is not None and all(k in expected for k in keys)
        equal = comparable and all(expected[k] == actual[k] or (isinstance(expected[k], (int, float)) and isinstance(actual[k], (int, float)) and abs(expected[k]-actual[k]) < 1e-6) for k in keys)
        put("METRICS_RECOMPUTE_MATCH", equal and complete, comparable and not equal,
            "Rumus dihitung ulang dari burst/RX unik; PASS membutuhkan arsip lengkap dan nilai evidence manifest")
    return results


def validate_directory(input_dir, output_dir, manifest_path):
    from .log_merge import read_json_events
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8-sig"))
    result = validate_logs(read_json_events(Path(input_dir).rglob("*.jsonl")), manifest)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir/"log_validation.json"
    path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return {"report": str(path), "counts": {k: sum(r["result"] == k for r in result) for k in ("PASS", "FAIL", "INCONCLUSIVE")},
            "synthetic_data": manifest.get("synthetic_data", False), "checks": result}
