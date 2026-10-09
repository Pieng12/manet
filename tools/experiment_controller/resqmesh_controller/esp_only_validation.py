"""Scenario evidence, separate from delivery and the four research metrics."""
from .neighbor_testbed import ESP_ONLY, recovery_profile, scenario_parameters, testbed


def scenario_checks(events, record, manifest):
    from .log_merge import _timestamp
    from .neighbor_experiment import flatten, stable_id
    from .mpl_validation import _inventory, _state, _covers

    scope = stable_id(record["device_trial_id"])
    profile = {"testbed_profile": manifest.get("testbed_profile", ESP_ONLY)}
    modern = recovery_profile(profile)
    design = testbed(profile)
    samples = [flatten(e) for e in events]
    samples = [e for e in samples if e.get("session_id") == manifest.get("session_id")
               and e.get("trial_id") == record["trial_id"] and (e.get("scope") == scope
               or modern and e.get("scope") is None and e.get("event_type") == "SOS_CREATED"
               and e.get("node_id") == design.source)]
    parameters = scenario_parameters(profile, record["hypothesis"])
    start, end = record.get("observation_started_at_ms"), record.get("observation_ended_at_ms")
    checks = []

    def put(name, result, detail):
        checks.append({"trial_id": record["trial_id"], "method": record["mode"],
                       "scenario": record["hypothesis"], "check": name,
                       "result": result, "evidence": detail})

    inactive = parameters["inactive_node_ids"]
    missing, contradictory = [], []
    activations = {}
    tolerance = int(manifest.get("activation_tolerance_ms", 10000))
    if start is None or end is None or end-start != parameters["observation_window_seconds"]*1000:
        missing.append("PHYSICAL_WINDOW")
    for node in inactive:
        changes = [e for e in samples if e.get("node_id") == node
                   and e.get("event_type") == "NODE_PARTICIPATION_CHANGED"]
        off = [e for e in changes if e.get("confirmed_enabled") is False
               and e.get("rx_enabled") is False and e.get("tx_enabled") is False
               and e.get("scanner_registered") is False]
        on = [e for e in changes if e.get("confirmed_enabled") is True
              and e.get("rx_enabled") is True and e.get("tx_enabled") is True
              and e.get("scanner_registered") is True]
        if start is None or not off or not on or any(_timestamp(e) is None for e in off + on):
            missing.append(node)
            continue
        activated = min(on, key=_timestamp)
        activations[node] = activated
        due = start + parameters["activate_at_seconds"] * 1000
        if min(_timestamp(e) for e in off) > start or not due <= _timestamp(activated) <= due+tolerance:
            contradictory.append(node)
        if any(e.get("confirmed_enabled") is False and
               (e.get("rx_enabled") is True or e.get("tx_enabled") is True) for e in changes):
            contradictory.append(node)
        if any(e.get("node_id") == node and e.get("event_type") == "DATA_RECEIVED"
               and _timestamp(e) is not None and start <= _timestamp(e) < _timestamp(activated)
               for e in samples):
            contradictory.append(node)
    if not inactive:
        contradictory.extend(e["node_id"] for e in samples
                             if e.get("event_type") == "NODE_PARTICIPATION_CHANGED"
                             and e.get("confirmed_enabled") is False)
    put("RECOVERY_SCENARIO_PARTICIPATION" if modern else "ESP_SCENARIO_PARTICIPATION", "FAIL" if contradictory else "INCONCLUSIVE" if missing else "PASS",
        f"OFF/ON sebelum SOS dan pada jadwal tetap; kurang: {missing}; kontradiksi: {contradictory}")

    if record["hypothesis"] != "S2_POST_DATA_STOP" or record["mode"] != "trickle_mpl":
        return checks

    def finish(result, detail):
        put("RECOVERY_POST_STOP_REPAIR" if modern else "ESP_POST_STOP_REPAIR", result, detail)
        return checks

    on = activations.get("esp-destination")
    created = [e for e in samples if e.get("event_type") == "SOS_CREATED"
               and e.get("node_id") == design.source and e.get("message_key") == record.get("message_key")]
    if on is None or len(created) != 1 or start is None or end is None:
        return finish("INCONCLUSIVE", "Identitas SOS atau event ON target belum lengkap.")
    state = created[0].get("state_identity")
    local = _state(state)
    if local is None:
        return finish("INCONCLUSIVE", "State SOS canonical belum tersedia.")
    on_at = _timestamp(on)
    activation_boot = on.get("local_boot_id")
    if type(activation_boot) is not int or activation_boot <= 0:
        return finish("INCONCLUSIVE", "Incarnation aktivasi E belum tersedia; tidak memakai bukti CONTROL dari incarnation lain.")
    bridge = [e for e in samples if e.get("node_id") == "esp-r2b"
              and _timestamp(e) is not None]
    timer = [e for e in bridge if e.get("timer_kind") == "data" and e.get("timer_key") == state]
    stopped = [e for e in timer if e.get("event_type") == "MPL_TIMER_STOPPED"
               and start <= _timestamp(e) < on_at]
    if not stopped:
        return finish("INCONCLUSIVE", "Belum terbukti timer DATA D berhenti sebelum E ON; stop CONTROL tidak cukup.")
    stop = max(stopped, key=lambda e: e.get("event_sequence", 0))
    if stop.get("buffer_retained") is not True or stop.get("active") is not False:
        return finish("FAIL", "Stop DATA tidak membuktikan buffer bertahan dan timer nonaktif.")
    if stop.get("expiration_count") != manifest.get("mpl_parameters", {}).get("mpl_data_expirations"):
        return finish("FAIL", "Batas expiration DATA berbeda dari manifest.")
    if any(e.get("event_sequence", 0) > stop.get("event_sequence", 0) and _timestamp(e) < on_at
           and e.get("event_type") in {"MPL_INTERVAL_STARTED", "MPL_TIMER_RESTARTED", "MPL_NATIVE_STARTED"}
           for e in timer):
        return finish("INCONCLUSIVE" if modern else "FAIL", "Timer DATA D aktif kembali sebelum E ON; kondisi pasca-stop belum terisolasi.")
    status = record.get("pre_activation_status", {})
    response = status.get("response", {})
    if (status.get("node_id") != "esp-r2b" or response.get("ok") is not True
            or response.get("session_id") != manifest.get("session_id")
            or response.get("trial_id") != record["device_trial_id"]
            or response.get("scope") != scope or status.get("captured_at_ms", on_at+1) > on_at):
        return finish("INCONCLUSIVE", "Snapshot D sebelum aktivasi belum cocok dengan scope dan waktu ON.")
    if response.get("packet_pending") is not True:
        return finish("FAIL", "SOS tidak tersedia di buffer D sebelum E ON.")
    peer = stable_id("esp-destination")
    proofs = [e for e in bridge if e.get("event_type") == "MPL_RX_CLASSIFIED"
              and e.get("frame_type") == "status" and e.get("peer_id") == peer
              and e.get("peer_boot") == activation_boot
              and e.get("snapshot_complete") is True and _timestamp(e) >= on_at
              and _inventory(e) is not None
              and not any(_covers(s, local) for s in _inventory(e))]
    pending = [e for e in timer if e.get("event_type") == "MPL_REPAIR_PENDING" and e.get("peer_id") == peer
               and any(p.get("peer_boot") == e.get("peer_boot")
                       and p.get("transmission_sequence") is not None
                       and p.get("transmission_sequence") == e.get("transmission_sequence")
                       and p.get("event_sequence", 0) <= e.get("event_sequence", 0) for p in proofs)]
    resets = [e for e in timer if e.get("event_type") == "MPL_REPAIR_RESET" and e.get("peer_id") == peer
              and any(p.get("peer_boot") == e.get("peer_boot")
                      and p.get("event_sequence", 0) <= e.get("event_sequence", 0) for p in pending)]
    allowed = [e for e in timer if e.get("event_type") == "MPL_TX_ALLOWED"
               and any(r.get("event_sequence", 0) < e.get("event_sequence", 0) for r in resets)]
    native = [e for e in timer if e.get("event_type") == "MPL_NATIVE_STARTED"
              and any(a.get("generation") == e.get("generation")
                      and a.get("event_sequence", 0) < e.get("event_sequence", 0) for a in allowed)]
    tx = [e for e in bridge if e.get("event_type") == "DATA_BURST_STARTED"
          and e.get("state_identity") == state and e.get("transmitter_id") == stable_id("esp-r2b")
          and on_at <= _timestamp(e) < end
          and any(n.get("event_sequence", 0) < e.get("event_sequence", 0)
                  and 0 <= _timestamp(e)-_timestamp(n) <= 1000 for n in native)]
    rx = [e for e in samples if e.get("node_id") == "esp-destination" and e.get("event_type") == "DATA_RECEIVED"
          and e.get("state_identity") == state and _timestamp(e) is not None
          and on_at <= _timestamp(e) < end
          and any(all(e.get(k) is not None and e.get(k) == t.get(k)
                      for k in ("scope", "transmitter_id", "boot_id", "transmission_sequence")) for t in tx)]
    if not rx:
        return finish("INCONCLUSIVE", "Rangkaian CONTROL peer E -> MISSING -> reset -> native DATA D -> RX E belum lengkap.")
    return finish("PASS", "Timer DATA D berhenti dengan buffer bertahan; CONTROL E memicu repair dan burst D yang sama diterima E.")
