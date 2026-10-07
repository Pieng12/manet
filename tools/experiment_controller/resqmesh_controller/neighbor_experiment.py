"""Versioned all-target experiment; legacy hop profiles retain their formulas."""
from __future__ import annotations

import hashlib
import base64
import json
import math
import random
import time
import zlib
from pathlib import Path
from typing import Any

from .controller import ExperimentController, TrialSpec
from .config import ConfigError, _valid_research_build_id
from .devices import DeviceError
from .radio import radio_readiness_errors

PROFILE = "neighbor_graph_v1"
VERSION = "resqmesh-neighbor-v1"
METHODS = ("basic_flooding", "trickle_no_suppression", "trickle", "trickle_neighbor_status")
SCENARIOS = ("S0_MAIN", "S1_DELAYED_RX", "S2_LATE_JOIN")
SOURCE = "android-source"
TARGETS = ("esp-r1a", "esp-r1b", "esp-r2a", "esp-r2b", "esp-destination")
EDGES = ((SOURCE, TARGETS[0]), (SOURCE, TARGETS[1]), (TARGETS[0], TARGETS[2]),
         (TARGETS[1], TARGETS[2]), (TARGETS[0], TARGETS[3]), (TARGETS[3], TARGETS[4]))
DEFAULTS = {"status_period_ms": 12000, "status_burst_ms": 500, "freshness_ms": 45000,
            "discovery_jitter_ms": 1500, "reset_cooldown_ms": 8000, "neighbor_capacity": 16}


def stable_id(node: str) -> int:
    return zlib.crc32(node.encode("utf-8")) & 0xffffffff


def adjacency(node: str) -> list[int]:
    return [stable_id(b if a == node else a) for a, b in EDGES if node in (a, b)]


def validate_neighbor_config(config: dict[str, Any]) -> None:
    errors = []
    nodes = config.get("nodes", [])
    ids = [n.get("node_id") for n in nodes]
    if len(ids) != 6 or set(ids) != {SOURCE, *TARGETS}:
        errors.append("required: Android SOURCE and five ESP receiver/relays")
    numeric = [stable_id(i) for i in ids if isinstance(i, str)]
    if len(set(numeric)) != 6 or 0 in numeric:
        errors.append("stable transmitter ID collision")
    for transport, key in (("adb", "serial"), ("serial", "port")):
        values = [str(n.get(key, "")).strip().upper() for n in nodes if n.get("transport") == transport]
        if any(not v for v in values) or len(set(values)) != len(values):
            errors.append(f"missing/duplicate {key}")
    if any(n.get("transport") != ("adb" if n.get("node_id") == SOURCE else "serial") for n in nodes):
        errors.append("source must be ADB, all targets serial")
    if tuple(config.get("modes", METHODS)) != METHODS:
        errors.append("all four methods required in canonical order; trial plan randomizes them")
    scenarios = config.get("scenarios", ["S0_MAIN"])
    if not scenarios or len(scenarios) != len(set(scenarios)) or not set(scenarios) <= set(SCENARIOS):
        errors.append("invalid scenarios")
    if config.get("gateway_enabled") or config.get("ack_enabled"):
        errors.append("gateway/completion ACK must be disabled")
    for key in ("android_build_id", "firmware_build_id"):
        if not _valid_research_build_id(config.get(key)):
            errors.append(f"{key} must identify the frozen source build (12-40 hex)")
    if config.get("android_build_id") != config.get("firmware_build_id"):
        errors.append("APK and firmware build IDs differ")
    if config.get("radio_mode", "coded") != "coded":
        errors.append("pilot uses coded; S8 is not verified")
    try:
        window = float(config["observation_window_seconds"])
        delay = float(config.get("perturbation_delay_seconds", 30))
        recovery = float(config.get("minimum_recovery_seconds", 120))
        if not all(math.isfinite(v) for v in (window, delay, recovery)) or window <= 0 or delay <= 0 or recovery <= 0:
            raise ValueError()
        if any(s != "S0_MAIN" for s in scenarios) and delay + recovery > window:
            errors.append("perturbation plus recovery must fit the physical t0 window")
        if int(config.get("valid_trials_per_condition", 15)) < 1:
            errors.append("replicates must be positive")
        if int(config.get("max_attempts_per_condition", 45)) < int(config.get("valid_trials_per_condition", 15)):
            errors.append("attempt budget smaller than replicate target")
        if config.get("trial_order", "balanced_randomized") != "balanced_randomized":
            errors.append("new profile requires balanced randomized blocks")
        if int(config.get("clock_tolerance_ms", -1)) < 0:
            errors.append("clock tolerance required")
        p = {**DEFAULTS, **config.get("neighbor_parameters", {})}
        if (p["status_period_ms"] < 1000 or not 250 <= p["status_burst_ms"] <= 2000 or
                p["freshness_ms"] < p["status_period_ms"] * 2 or p["discovery_jitter_ms"] < 0 or
                p["reset_cooldown_ms"] < 1000 or not 5 <= p["neighbor_capacity"] <= 64):
            errors.append("unsafe neighbor parameters")
    except (KeyError, ValueError, TypeError):
        errors.append("invalid duration/parameter")
    if errors:
        raise ConfigError("; ".join(errors))


def neighbor_fingerprint(config: dict[str, Any]) -> str:
    relevant = {k: v for k, v in config.items() if k not in {"session_id", "session_label", "valid_trials_per_condition", "trials_per_condition", "max_attempts_per_condition", "trial_order", "hypotheses"}}
    relevant.update(transport_version=VERSION, design_version=1, measurement_version=1, graph=EDGES,
                    neighbor_parameters={**DEFAULTS, **config.get("neighbor_parameters", {})})
    return hashlib.sha256(json.dumps(relevant, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def neighbor_plan(config: dict[str, Any]) -> list[TrialSpec]:
    rng = random.Random(int(config.get("random_seed", 231402095)))
    rows = []
    for block in range(1, int(config.get("valid_trials_per_condition", 15)) + 1):
        combinations = [TrialSpec(m, s, block, block) for m in METHODS for s in config.get("scenarios", ["S0_MAIN"])]
        rng.shuffle(combinations)
        rows.extend(combinations)
    return rows


def flatten(event: dict[str, Any]) -> dict[str, Any]:
    detail = event.get("detail_json") or event.get("detail") or {}
    if isinstance(detail, str):
        detail = json.loads(detail)
    return {**detail, **event, "node_id": event.get("node_id", event.get("device_id", detail.get("node_id")))}


def summarize_network(events: list[dict[str, Any]], record: dict[str, Any]) -> dict[str, Any]:
    from .log_merge import _timestamp
    events = [flatten(e) for e in events]
    events = [e for e in events
              if (record.get("session_id") is None or e.get("session_id") == record["session_id"])
              and (record.get("trial_id") is None or e.get("trial_id") == record["trial_id"])
              and (record.get("scope") is None or e.get("scope") == record["scope"]
                   or (e.get("scope") is None and e.get("event_type") in
                       {"SOS_CREATED", "SOURCE_FIRST_ADVERTISE_STARTED"}))]
    start, end = record.get("observation_started_at_ms"), record.get("observation_ended_at_ms")
    if start is None or end is None:
        raise ValueError("Physical observation window required")
    source_messages = {e.get("message_key") for e in events if e.get("event_type") == "SOS_CREATED" and e.get("node_id") == SOURCE and e.get("message_key")}
    starts = {}
    for e in events:
        if e.get("event_type") == "SOURCE_FIRST_ADVERTISE_STARTED" and e.get("node_id") == SOURCE and e.get("message_key") in source_messages:
            t = _timestamp(e)
            if t is not None:
                starts[e["message_key"]] = min(t, starts.get(e["message_key"], t))
    accepted, first, seen = [], {}, set()
    data_tx, control_tx, setup_control = set(), set(), set()
    for e in events:
        t = _timestamp(e)
        if t is None:
            continue
        node = e.get("node_id", e.get("device_id"))
        if node not in (SOURCE, *TARGETS):
            continue
        if record.get("scope") is not None and e.get("scope") != record["scope"]:
            continue
        in_window = start <= t < end
        kind = e.get("event_type")
        burst = (node, e.get("scope"), e.get("transmitter_id"), e.get("boot_id"), e.get("transmission_sequence"))
        complete_id = all(v is not None for v in burst)
        valid_tx = complete_id and e["transmitter_id"] == stable_id(node)
        if kind == "STATUS_BURST_STARTED" and valid_tx:
            if in_window:
                control_tx.add(burst)
            elif t < start:
                setup_control.add(burst)
        if kind == "DATA_BURST_STARTED" and in_window and valid_tx and e.get("message_key") in source_messages:
            data_tx.add(burst)
        if kind != "DATA_RECEIVED" or not in_window or node not in TARGETS or not complete_id or e.get("message_key") not in source_messages:
            continue
        if e["transmitter_id"] not in adjacency(node) or burst in seen:
            continue
        seen.add(burst)
        accepted.append(e)
        pair = (e["message_key"], node)
        first[pair] = min(t, first.get(pair, t))
    latency = []
    for (message, node), t in sorted(first.items()):
        source_at = starts.get(message)
        clocks = record.get("clock_samples", {})
        bounds = [clocks.get(n, {}).get("uncertainty_ms") for n in (SOURCE, node)]
        uncertainty = sum(bounds) if all(v is not None for v in bounds) else None
        latency.append({"message_key": message, "receiver": node, "first_rx_at_ms": t,
                        "e2e_latency_ms": None if source_at is None else t - source_at,
                        "clock_uncertainty_ms": uncertainty,
                        "clock_tolerance_ms": record.get("clock_tolerance_ms")})
    values = [v["e2e_latency_ms"] for v in latency if v["e2e_latency_ms"] is not None]
    m, r, u = len(source_messages), len(accepted), len(first)
    return {"measurement_version": "all-node-burst-v1", "M": m, "N": 5, "U": u, "R": r,
            "dsr_percent": 100 * u / (m * 5) if m else None,
            "ldr_percent": 100 * (r-u) / r if r else None,
            "e2e_mean_ms": sum(values)/len(values) if values else None,
            "successful_pairs": u, "data_tx": len(data_tx), "control_tx": len(control_tx),
            "network_overhead": len(data_tx)+len(control_tx), "setup_control_tx": len(setup_control),
            "setup_plus_window_tx": len(setup_control)+len(data_tx)+len(control_tx),
            "per_receiver": latency}


class NeighborExperimentController(ExperimentController):
    def __init__(self, config, nodes, output_dir, sleep=time.sleep):
        normalized = {**config, "hypotheses": config.get("scenarios", ["S0_MAIN"]), "modes": list(METHODS)}
        super().__init__(normalized, nodes, output_dir, sleep)

    def _load_manifest(self):
        value = super()._load_manifest()
        value.update(transport_profile=PROFILE, transport_version=VERSION, neighbor_design_version=1,
                     measurement_version="all-node-burst-v1", topology_basis="stable_transmitter_logical_graph_not_RF_isolation",
                     target_valid_trials=4 * len(self.config["hypotheses"]) * self.valid_target,
                     neighbor_scenarios=list(self.config["hypotheses"]),
                     graph=EDGES, target_node_ids=list(TARGETS), neighbor_parameters={**DEFAULTS, **self.config.get("neighbor_parameters", {})})
        value["reporting_version"] = "neighbor-descriptive-v1"
        value["phy_claim_limit"] = "LE Coded; coding aktual UNKNOWN/UNVERIFIED kecuali ada bukti on-air; bukan otomatis S=8/125 kbps"
        value["cost_basis"] = "Burst logis berhasil dimulai; setup_plus_window_tx bukan seluruh biaya siklus hidup"
        from .config import METHOD_PARAMETERS
        value["method_parameters"] = {**METHOD_PARAMETERS, "trickle_neighbor_status": {
            "scheduler": "trickle", "suppression_basis": "fresh_observed_neighbor_inventory",
            "imin_ms": 8000, "imax_ms": 256000, "imax_doublings":5,
            "k": 1, "burst_ms": 2000,"c_suppression_enabled":False,"neighbor_suppression_enabled":True,
            **value["neighbor_parameters"]}}
        return value

    def _node_topology(self, node, hypothesis):
        return {"role": "SOURCE" if node.node_id == SOURCE else "RELAY", "active": True,
                "expected_hop_in": None, "hop_out": 1 if node.node_id == SOURCE else 0}

    def readiness(self, spec=None, after_reset=False, require_active_trial=False):
        results, failures = {}, []
        for node in self.nodes:
            result = node.command("readiness", {"command_id": self._command_id("neighbor-ready", node.node_id)})
            # Never replace a measured trial offset with a later preflight clock command.
            if spec is None and node.transport == "serial" and not result.get("clock_valid") and not result.get("trial_id"):
                synced = node.command("clock_sync", {"command_id": self._command_id("neighbor-preflight-clock", node.node_id),
                                                      "wall_time_ms": time.time_ns() // 1_000_000})
                if synced.get("ok") is not True:
                    raise DeviceError(f"preflight clock failed: {node.node_id}")
                result = node.command("readiness", {"command_id": self._command_id("neighbor-ready-after-clock", node.node_id)})
            results[node.node_id] = result
            self.manifest.setdefault("radio_readiness", {})[node.node_id] = result.get("radio")
            from .neighbor_reporting import phy_evidence
            self.manifest.setdefault("phy_evidence", {})[node.node_id] = phy_evidence(result.get("radio"))
            errors = self._readiness_errors(node, result, spec, after_reset, require_active_trial)
            if errors:
                failures.append(f"{node.node_id}: {'; '.join(errors)}")
        if failures:
            raise DeviceError("readiness failed: " + " | ".join(failures))
        return results

    def recover_interrupted_trials(self, readiness):
        known = {r["device_trial_id"] for r in self.manifest["trials"].values()}
        foreign = {node: r["trial_id"] for node, r in readiness.items()
                   if r.get("trial_id") and r["trial_id"] not in known}
        if foreign:
            raise DeviceError(f"Unarchived/foreign active trial; finish and archive explicitly: {foreign}")
        super().recover_interrupted_trials(readiness)

    def synchronize_clocks(self, spec):
        samples={}
        for node in self.nodes:
            before=time.time_ns()/1_000_000
            if hasattr(node,"host_clock_offset_ms"):
                offset=float(node.host_clock_offset_ms())
            else:
                response=node.command("clock_sync",{"command_id":self._command_id("clock",spec.trial_id,node.node_id),"wall_time_ms":int(before)})
                if response.get("ok") is not True: raise DeviceError(f"clock sync failed: {node.node_id}")
                offset=(time.time_ns()/1_000_000-before)/2
            after=time.time_ns()/1_000_000
            uncertainty=(after-before)/2+1
            if uncertainty > self.config['clock_tolerance_ms']:
                raise DeviceError(f"clock uncertainty exceeds tolerance: {node.node_id}: {uncertainty:.1f}ms")
            self.clock_offsets[node.node_id]=offset
            samples[node.node_id]={"offset_ms":offset,"uncertainty_ms":uncertainty,"before_ms":before,"after_ms":after}
        self.manifest['clock_sync']={"valid":True,"captured_at_ms":time.time_ns()//1_000_000,"offset_ms_by_node":self.clock_offsets,"samples":samples}
        self.manifest['trials'].get(spec.trial_id,{}).update(clock_samples=samples)
        self._save_manifest()

    def _readiness_errors(self, node, result, spec, after_reset, require_active_trial):
        errors = radio_readiness_errors(result.get("radio"), "coded", spec is not None)
        if result.get("ok") is not True:
            errors.append("ok=false")
        if result.get("neighbor_design_version") != 1:
            errors.append("neighbor design version mismatch")
        if result.get("build_id") != self.config["android_build_id"]:
            errors.append("build mismatch")
        if node.node_id == SOURCE and result.get("radio", {}).get("maximum_advertising_data_length", 0) < 90:
            errors.append("adapter cannot fit largest STATUS plus manufacturer header")
        if result.get("protocol_version") != "resqmesh-ble17-v1" or result.get("payload_length") != 17 or result.get("manufacturer_id") != 65535:
            errors.append("inner protocol mismatch")
        if node.transport == "adb" and (not result.get("bluetooth") or
                not all(result.get("permissions", {}).get(p) is True for p in ("scan", "advertise"))):
            errors.append("Bluetooth/permission unavailable")
        if spec is not None and not after_reset and result.get("transport_profile") != PROFILE:
            errors.append("transport profile mismatch")
        epoch = result.get("protocol_epoch", result)
        if epoch.get("valid", epoch.get("epoch_valid")) is not True or result.get("clock_valid", True) is not True:
            errors.append("invalid epoch/clock")
        if require_active_trial and result.get("trial_id") != self._device_trial_id(spec):
            errors.append("trial scope mismatch")
        if result.get("scanner") is not True and not (result.get('advertising') is True and result.get('rx_participation') is True):
            errors.append("scanner registration missing")
        if after_reset and (result.get("packet_pending") or result.get("advertising") or result.get("queue_size") or not result.get("quiet_period_complete", False)):
            errors.append("reset/quiet verification failed")
        if after_reset and result.get("trial_id"):
            errors.append("trial still active after reset")
        if spec is not None and not after_reset:
            expected = {"suppression_enabled": spec.mode == 'trickle', "trickle_imin_ms":8000,
                        "trickle_imax_ms":256000,"trickle_k":1,"burst_duration_ms":2000,
                        "session_id":self.manifest['session_id'], "transmitter_id":stable_id(node.node_id),
                        "allowed_transmitters":adjacency(node.node_id),
                        "neighbor_parameters":{**DEFAULTS, **self.config.get('neighbor_parameters',{})},
                        "transport_version":VERSION, "data_frame_length":39}
            for key, value in expected.items():
                actual=result.get(key)
                if key=='allowed_transmitters':
                    actual=sorted(actual or []);value=sorted(value)
                if actual!=value: errors.append(f"{key} mismatch")
            if require_active_trial and result.get('scope')!=stable_id(self._device_trial_id(spec)):
                errors.append('on-air trial scope mismatch')
            if result.get("mode") != spec.mode or result.get("role") != ("SOURCE" if node.node_id == SOURCE else "RELAY"):
                errors.append("mode/role mismatch")
            if result.get("protocol_active") is not True or result.get("gateway_enabled", False) or result.get("ack_enabled", False):
                errors.append("participation/gateway/ACK configuration mismatch")
        return errors

    def configure(self, spec):
        from . import PROTOCOL_EPOCH_ID, PROTOCOL_EPOCH_SECONDS, PROTOCOL_VERSION
        for node in self.nodes:
            args = {"command_id": self._command_id("cfg", spec.trial_id, node.node_id),
                    "session_id": self.manifest["session_id"], "session_code": f"{spec.mode}-{spec.hypothesis}",
                    "node_id": node.node_id, "role": "SOURCE" if node.node_id == SOURCE else "RELAY",
                    "target_hop": 0, "hypothesis": spec.hypothesis, "topology": PROFILE,
                    "expected_hop_in": 0, "hop_out": 1 if node.node_id == SOURCE else 0,
                    "mode": spec.mode, "build_id": self.config["android_build_id"],
                    "protocol_version": PROTOCOL_VERSION, "transport_profile": PROFILE,
                    "protocol_epoch_id": PROTOCOL_EPOCH_ID, "protocol_epoch_seconds": PROTOCOL_EPOCH_SECONDS,
                    "radio_mode": "coded", "main_experiment": True, "protocol_active": True,
                    "observation_window_ms": int(self.config["observation_window_seconds"]*1000),
                    "rx_burst_gap_ms": int(self.config.get("rx_burst_gap_ms", 1000)),
                    "allowed_transmitters": adjacency(node.node_id),
                    "clock_offset_ms": self.clock_offsets.get(node.node_id, 0),
                    "clock_tolerance_ms": self.config["clock_tolerance_ms"],
                    **DEFAULTS, **self.config.get("neighbor_parameters", {})}
            result = node.command("configure_session", args)
            if result.get("ok") is not True:
                raise DeviceError(f"configuration failed: {node.node_id}: {result}")

    def _perturb(self, spec, enabled):
        if spec.hypothesis == "S0_MAIN":
            return
        node_id, command = ("esp-r2b", "set_rx_participation") if spec.hypothesis == "S1_DELAYED_RX" else ("esp-destination", "set_node_participation")
        node = next(n for n in self.nodes if n.node_id == node_id)
        requested = time.time_ns()//1_000_000
        response = node.command(command, {"command_id": self._command_id("participation", spec.trial_id, str(enabled)), "enabled": enabled})
        self.manifest["trials"][spec.trial_id].setdefault("participation", []).append({"node": node_id, "requested_at_ms": requested, "confirmed_at_ms": time.time_ns()//1_000_000, "enabled": enabled, "response": response})
        self._save_manifest()
        if response.get("ok") is not True or response.get("confirmed_enabled") is not enabled:
            raise DeviceError("participation not confirmed")

    def before_trigger(self, spec):
        self._perturb(spec, False)

    def observe_until(self, spec, deadline):
        if spec.hypothesis != "S0_MAIN":
            t0 = self.manifest["trials"][spec.trial_id]["observation_started_at_ms"]
            due = t0 + self.config.get("perturbation_delay_seconds", 30)*1000
            self._wait_until(time.monotonic()+max(0,(due-time.time_ns()//1_000_000)/1000))
            self._perturb(spec, True)
        self._wait_until(deadline)

    def _wait_until(self, deadline):
        while time.monotonic()<deadline:
            for node in self.nodes:
                if getattr(node,'transport_error',None): raise DeviceError(node.transport_error)
            self.sleep(min(.25,max(0,deadline-time.monotonic())))

    def archive_failed_trial(self, spec, record):
        from .devices import write_jsonl
        errors = []
        for node in self.nodes:
            path = self.output_dir / "raw" / spec.trial_id / f"{node.node_id}.jsonl"
            if path.exists():
                continue
            try:
                if hasattr(node, "diagnostic_events"):
                    events = node.diagnostic_events(record["session_id"], record["device_trial_id"])
                else:
                    events = node.collect_events(record["session_id"], record["device_trial_id"])
                write_jsonl(path, [{**e, "device_trial_id": record["device_trial_id"],
                                   "trial_id": spec.trial_id,
                                   "native_clock_offset_ms": e.get("clock_offset_ms"),
                                   "clock_offset_ms": self.clock_offsets.get(node.node_id, 0)} for e in events])
            except Exception as error:
                errors.append(f"{node.node_id}: {error}")
        record["failure_archive_errors"] = errors

    def _evaluate_events(self, spec, events, source_node, message_key, record):
        record.update(scope=stable_id(self._device_trial_id(spec)), scenario=spec.hypothesis,
                      target_node_ids=list(TARGETS), measurement_version="all-node-burst-v1")
        metrics = summarize_network(events, record)
        invalid = [str(e.get("reason", "CONFIG_VIOLATION")) for e in events if e.get("event_type") == "EXPERIMENT_CONFIG_VIOLATION"]
        if metrics["M"] != 1:
            invalid.append("REQUIRES_ONE_UNIQUE_SOS")
        if {e.get("message_key") for e in events if e.get("event_type")=="SOS_CREATED" and e.get("node_id")==SOURCE} != {message_key}:
            invalid.append("SOURCE_MESSAGE_KEY_MISMATCH")
        if any(p["e2e_latency_ms"] is None or p["e2e_latency_ms"] < 0 for p in metrics["per_receiver"]):
            invalid.append("RX_CLOCK_INVALID")
        if not any(e.get("event_type") == "SOURCE_FIRST_ADVERTISE_STARTED" for e in events):
            invalid.append("SOURCE_START_MISSING")
        from .log_merge import _timestamp
        for e in map(flatten, events):
            if e.get("event_type") in {"DATA_RECEIVED", "DATA_BURST_STARTED", "STATUS_BURST_STARTED"}:
                if _timestamp(e) is None or any(e.get(k) is None for k in ("scope", "transmitter_id", "boot_id", "transmission_sequence")):
                    invalid.append("TRANSPORT_OR_NATIVE_CLOCK_EVIDENCE_MISSING")
        for node in TARGETS:
            stream = [e.get("event_sequence") for e in events if e.get("node_id") == node]
            if not stream or any(not isinstance(s, int) for s in stream) or sorted(set(stream)) != list(range(min(stream), max(stream)+1)) or len(stream) != len(set(stream)):
                invalid.append(f"EVENT_SEQUENCE_INCOMPLETE:{node}")
        if metrics["data_tx"] < 1:
            invalid.append("SUCCESSFUL_SOURCE_DATA_START_MISSING")
        if not any(e.get("event_type")=="DATA_BURST_STARTED" and e.get("node_id")==SOURCE and e.get("message_key")==message_key for e in events):
            invalid.append("SOURCE_DATA_START_MISSING")
        source = next(n for n in self.nodes if n.node_id == SOURCE)
        summary = {"session_id": record["session_id"], "trial_id": record["device_trial_id"],
                   "method": spec.mode, "scenario": spec.hypothesis, **metrics,
                   "result": "INVALID" if invalid else "SUCCESS" if metrics["U"] == 5 else "FAILED_DELIVERY"}
        try:
            response = source.command("store_neighbor_metrics", {
                "command_id": self._command_id("network-summary", spec.trial_id),
                "summary_base64": base64.b64encode(json.dumps(summary, separators=(",", ":")).encode()).decode()})
            record["ui_summary_confirmed"] = response.get("ok") is True
        except DeviceError as error:
            record["ui_summary_confirmed"] = False
            record["ui_summary_error"] = str(error)
        return ("INVALID" if invalid else "SUCCESS" if metrics["U"] == 5 else "FAILED_DELIVERY"), invalid, metrics

    def smoke_report(self):
        rows = [{"mode": m, "hypothesis": s, "result": next((r["result"] for r in self.manifest["trials"].values() if r["mode"] == m and r["hypothesis"] == s), "MISSING")}
                for m in METHODS for s in self.config["hypotheses"]]
        report = {"passed": all(r["result"] in {"SUCCESS", "FAILED_DELIVERY"} for r in rows),
                  "config_fingerprint": self.config_fingerprint, "session_id": self.manifest["session_id"], "conditions": rows}
        (self.output_dir/"smoke_report.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
        import csv
        with (self.output_dir/"smoke_report.csv").open("w",newline="",encoding="utf-8-sig") as f:
            writer=csv.DictWriter(f,fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
        return report


def merge_neighbor(input_dir: Path, output_dir: Path, manifest: dict[str, Any]):
    from .log_merge import read_json_events
    from .excel_report import _write_table
    from openpyxl import Workbook
    from .neighbor_reporting import aggregate, mechanism_counts, phy_evidence, write_charts
    from .neighbor_validation import validate_logs
    raw_events = read_json_events(input_dir.rglob("*.jsonl"))
    events = [flatten(e) for e in raw_events if e.get("session_id") == manifest["session_id"] and e.get("trial_id") in manifest["trials"]]
    rows, receivers = [], []
    for trial_id, record in manifest["trials"].items():
        scoped = [e for e in events if e.get("trial_id") == trial_id]
        metrics = summarize_network(scoped, {**record, "trial_id": trial_id, "session_id": manifest["session_id"], "scope": stable_id(record["device_trial_id"])}) if all(record.get(k) is not None for k in ("observation_started_at_ms", "observation_ended_at_ms")) else {}
        rows.append({"trial_id": trial_id, "method": record["mode"], "scenario": record["hypothesis"], "analysis_group": "utama" if record["hypothesis"] == "S0_MAIN" else "pendukung", "result": record["result"], "valid": record["result"] in {"SUCCESS","FAILED_DELIVERY"}, "invalid_reasons": record.get("invalid_reasons",[]), "block": record.get("block"), "observation_started_at_ms": record.get("observation_started_at_ms"), "observation_ended_at_ms": record.get("observation_ended_at_ms"), "config_fingerprint": record.get("config_fingerprint"), **{k:v for k,v in metrics.items() if k!="per_receiver"}})
        for target in TARGETS:
            pair = next((p for p in metrics.get("per_receiver", []) if p["receiver"] == target), {})
            receivers.append({"trial_id": trial_id, "method": record["mode"], "scenario": record["hypothesis"], "valid": rows[-1]["valid"], "receiver": target, "received": bool(pair), "first_rx_at_ms":pair.get("first_rx_at_ms"), "e2e_latency_ms": pair.get("e2e_latency_ms"), "clock_uncertainty_ms": pair.get("clock_uncertainty_ms"), "clock_tolerance_ms": record.get("clock_tolerance_ms")})
    scenarios = manifest.get("neighbor_scenarios", sorted({r["scenario"] for r in rows}))
    summaries, stats = aggregate(rows, receivers, scenarios, METHODS)
    diagnostics = mechanism_counts(events, manifest["trials"])
    phy = [{"node_id": node, **phy_evidence(radio)} for node, radio in manifest.get("radio_readiness", {}).items()]
    validation = validate_logs(events, manifest)
    output_dir.mkdir(parents=True,exist_ok=True)
    wb=Workbook(); wb.remove(wb.active)
    _write_table(wb,"Overview",[{"field":k,"value":v} for k,v in manifest.items() if k!="trials"])
    _write_table(wb,"Metric Definitions",[
        {"metrik":"DSR","rumus":"U/(M*5)*100","catatan":"FAILED_DELIVERY tetap masuk denominator"},
        {"metrik":"E2E","rumus":"RX native pertama - DATA sumber pertama","catatan":"Rata-rata pasangan sukses; gagal kosong"},
        {"metrik":"LDR","rumus":"(R-U)/R*100","catatan":"STATUS dikecualikan; R=0 kosong"},
        {"metrik":"Overhead","rumus":"DATA_TX + CONTROL_TX","catatan":"Burst logis berhasil dimulai seluruh enam node, hanya dalam window; bukan energi/paket RF"},
        {"metrik":"Setup + window","rumus":"setup_control_tx + network_overhead","catatan":"STATUS persiapan trial yang sama + window; bukan seluruh biaya siklus hidup"},
        {"metrik":"Statistik per trial","rumus":"Mean, median, SD sampel, min, max atas trial valid","catatan":"FAILED_DELIVERY termasuk; INVALID terpisah; nilai tidak terdefinisi kosong; SD kosong bila n terdefinisi < 2"},
        {"metrik":"Delay per trial vs pasangan","rumus":"e2e_mean_ms_trial_mean vs e2e_mean_ms","catatan":"Rata-rata trial tanpa bobot vs rata-rata semua pasangan sukses; bukan nilai nol untuk kegagalan"}])
    _write_table(wb,"Trial Metrics",rows)
    _write_table(wb,"Method Scenario Summary",summaries)
    _write_table(wb,"Descriptive Statistics",stats)
    _write_table(wb,"Mechanism Diagnostics",diagnostics)
    _write_table(wb,"PHY Evidence",phy)
    _write_table(wb,"Log Validation",validation)
    _write_table(wb,"Receivers",receivers)
    _write_table(wb,"All Events",events)
    _write_table(wb,"Participation",[{"trial_id":trial_id,**p} for trial_id, record in manifest["trials"].items() for p in record.get("participation",[])])
    from .excel_report import _method_parameter_rows
    parameters = _method_parameter_rows(manifest)
    for row in parameters:
        if row['mode'] == 'trickle_neighbor_status':
            for key in ('basic_wait_ms','jitter_min_ms','jitter_max_ms','k'):
                row[key] = 'N/A'
            row['suppression_enabled'] = True
            row['parameter_notes'] = 'Keputusan DATA berdasarkan HAVE/MISSING/UNKNOWN tetangga teramati; bukan c/k'
            row['transmission_timing'] = 't acak dalam [I/2,I); STATUS terpisah memakai discovery jitter'
    _write_table(wb,"Method Parameters",parameters)
    _write_table(wb,"Invalid Trials",[r for r in rows if r["result"]=="INVALID"])
    chart_paths = write_charts(output_dir/"charts", summaries, stats, scenarios, METHODS, manifest.get("synthetic_data") is True)
    _write_table(wb,"Charts",[{"artifact":Path(p).name,"catatan":"Buka SVG; grafik delay menyertakan jumlah pasangan sukses dan DSR agregat","path":str(Path("charts")/Path(p).name)} for p in chart_paths])
    for row in range(2, len(chart_paths)+2):
        wb["Charts"].cell(row, 3).hyperlink = str(Path("charts")/Path(chart_paths[row-2]).name)
        wb["Charts"].cell(row, 3).style = "Hyperlink"
    path=output_dir/"resqmesh_neighbor_analysis.xlsx"; wb.save(path)
    (output_dir/"network_metrics.json").write_text(json.dumps(rows,indent=2),encoding="utf-8")
    (output_dir/"all_events.json").write_text(json.dumps(raw_events,indent=2),encoding="utf-8")
    (output_dir/"method_scenario_summary.json").write_text(json.dumps(summaries,indent=2),encoding="utf-8")
    (output_dir/"manifest_snapshot.json").write_text(json.dumps(manifest,indent=2),encoding="utf-8")
    for name, data in (("descriptive_statistics", stats), ("mechanism_diagnostics", diagnostics), ("phy_evidence", phy), ("log_validation", validation)):
        (output_dir/f"{name}.json").write_text(json.dumps(data,indent=2),encoding="utf-8")
    import csv
    for name, data in (("trial_metrics",rows),("receivers",receivers),("all_events",events),("method_scenario_summary",summaries), ("descriptive_statistics",stats), ("mechanism_diagnostics",diagnostics), ("phy_evidence",phy), ("log_validation",validation)):
        with (output_dir/f"{name}.csv").open("w",newline="",encoding="utf-8-sig") as f:
            fields=list(dict.fromkeys(k for row in data for k in row)) or ["trial_id"]
            writer=csv.DictWriter(f,fieldnames=fields); writer.writeheader()
            writer.writerows({k: json.dumps(v,ensure_ascii=False) if isinstance(v,(dict,list)) else v for k,v in row.items()} for row in data)
    return {"workbook":str(path),"trial_count":len(rows),"event_count":len(events), "charts":chart_paths, "validation":"log_validation.json", "synthetic_data":manifest.get("synthetic_data", False)}
