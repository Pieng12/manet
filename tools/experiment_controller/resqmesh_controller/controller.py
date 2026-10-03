from __future__ import annotations

import csv
import json
import os
import random
import time
import uuid
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from . import PROTOCOL_EPOCH_ID, PROTOCOL_EPOCH_SECONDS, PROTOCOL_VERSION
from .config import HYPOTHESES, MODES, research_fingerprint, validate_config
from .devices import DeviceError, NodeTransport, write_jsonl
from .radio import radio_readiness_errors
from .log_merge import (
    canonical_message_key,
    canonical_state_identity,
    event_within_observation_window,
    research_event_integrity_errors,
)


@dataclass(frozen=True)
class TrialSpec:
    mode: str
    hypothesis: str
    number: int

    @property
    def trial_id(self) -> str:
        return f"{self.mode}-{self.hypothesis}-A{self.number:03d}"

    def to_json(self) -> dict[str, Any]:
        return {
            "trial_id": self.trial_id,
            "mode": self.mode,
            "hypothesis": self.hypothesis,
            "attempt": self.number,
        }

    @classmethod
    def from_json(cls, value: dict[str, Any]) -> "TrialSpec":
        return cls(str(value["mode"]), str(value["hypothesis"]), int(value["attempt"]))


class BatchIncompleteError(RuntimeError):
    def __init__(self, summary: dict[str, Any]) -> None:
        super().__init__("valid-trial target was not reached before max attempts")
        self.summary = summary


def build_plan(config: dict[str, Any]) -> list[TrialSpec]:
    target = int(config.get("valid_trials_per_condition", config.get("trials_per_condition", 15)))
    plan = [
        TrialSpec(mode, hypothesis, number)
        for mode in config.get("modes", MODES)
        for hypothesis in config.get("hypotheses", HYPOTHESES)
        for number in range(1, target + 1)
    ]
    if config.get("trial_order", "blocked") == "randomized":
        random.Random(int(config.get("random_seed", 231402095))).shuffle(plan)
    return plan


class ExperimentController:
    def __init__(
        self,
        config: dict[str, Any],
        nodes: list[NodeTransport],
        output_dir: Path,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        validate_config(config)
        self.config = config
        self.nodes = nodes
        self.output_dir = output_dir
        self.sleep = sleep
        self.manifest_path = output_dir / "manifest.json"
        self.config_fingerprint = research_fingerprint(config)
        self.manifest = self._load_manifest()
        self.clock_offsets: dict[str, float] = {}

    @property
    def valid_target(self) -> int:
        return int(
            self.config.get(
                "valid_trials_per_condition",
                self.config.get("trials_per_condition", 15),
            )
        )

    @property
    def max_attempts(self) -> int:
        return int(self.config.get("max_attempts_per_condition", max(45, self.valid_target)))

    def _load_manifest(self) -> dict[str, Any]:
        if self.manifest_path.exists():
            manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
            existing = manifest.get("config_fingerprint")
            if existing and existing != self.config_fingerprint:
                raise DeviceError("manifest config/topology fingerprint does not match this configuration")
            manifest.setdefault("config_fingerprint", self.config_fingerprint)
            manifest.setdefault("trials", {})
            manifest.setdefault("trial_order", [item.to_json() for item in build_plan(self.config)])
            return manifest
        return {
            "session_id": self.config.get("session_id", f"session-{uuid.uuid4().hex[:8]}"),
            "epoch_id": PROTOCOL_EPOCH_ID,
            "protocol_version": PROTOCOL_VERSION,
            "config_fingerprint": self.config_fingerprint,
            "valid_trials_per_condition": self.valid_target,
            "max_attempts_per_condition": self.max_attempts,
            "trial_order_strategy": self.config.get("trial_order", "blocked"),
            "random_seed": int(self.config.get("random_seed", 231402095)),
            "trial_order": [item.to_json() for item in build_plan(self.config)],
            "trials": {},
            "radio_mode": self.config.get("radio_mode"),
            "android_build_id": self.config.get("android_build_id"),
            "firmware_build_id": self.config.get("firmware_build_id"),
        }

    def _save_manifest(self) -> None:
        self.output_dir.mkdir(parents=True, exist_ok=True)
        temporary = self.manifest_path.with_name(
            f".{self.manifest_path.name}.{uuid.uuid4().hex}.tmp"
        )
        temporary.write_text(json.dumps(self.manifest, indent=2, sort_keys=True), encoding="utf-8")
        for attempt in range(10):
            try:
                os.replace(temporary, self.manifest_path)
                return
            except PermissionError:
                if attempt == 9:
                    raise
                time.sleep(0.02 * (attempt + 1))

    def _command_id(self, prefix: str, *parts: str) -> str:
        return "-".join((prefix, self.manifest["session_id"], *parts))

    def _device_trial_id(self, spec: TrialSpec) -> str:
        return f"{spec.trial_id}--{self.manifest['session_id']}"

    def _node_topology(self, node: NodeTransport, hypothesis: str) -> dict[str, Any]:
        configured = next(item for item in self.config["nodes"] if item["node_id"] == node.node_id)
        return {**configured, **configured["topology"][hypothesis]}

    def _readiness_errors(
        self,
        node: NodeTransport,
        result: dict[str, Any],
        spec: TrialSpec | None,
        after_reset: bool,
        require_active_trial: bool,
    ) -> list[str]:
        errors: list[str] = []
        epoch = result.get("protocol_epoch", result)
        if result.get("ok") is not True:
            errors.append("ok=false")
        if result.get("measurement_timing_version") != 2:
            errors.append("measurement_timing_version=2 required; update APK/firmware")
        node_config = next(item for item in self.config["nodes"] if item["node_id"] == node.node_id)
        requested_radio = node_config.get("radio_mode", self.config.get("radio_mode"))
        radio = result.get("radio")
        if requested_radio is not None or radio is not None:
            errors.extend(radio_readiness_errors(radio, requested_radio or "coded", spec is not None))
        if epoch.get("valid", epoch.get("epoch_valid")) is not True:
            errors.append("protocol epoch is invalid")
        if epoch.get("epoch_id") != PROTOCOL_EPOCH_ID:
            errors.append(f"epoch_id={epoch.get('epoch_id')!r}")
        if result.get("clock_valid", True) is not True:
            errors.append("clock is not valid")
        if result.get("payload_length", 17) != 17:
            errors.append(f"payload_length={result.get('payload_length')!r}")
        if result.get("manufacturer_id", 0xFFFF) != 0xFFFF:
            errors.append(f"manufacturer_id={result.get('manufacturer_id')!r}")
        if result.get("protocol_version", PROTOCOL_VERSION) != PROTOCOL_VERSION:
            errors.append(f"protocol_version={result.get('protocol_version')!r}")
        expected_rx_burst_gap = int(self.config["rx_burst_gap_ms"])
        if result.get("rx_burst_gap_ms") != expected_rx_burst_gap:
            errors.append(
                f"rx_burst_gap_ms={result.get('rx_burst_gap_ms')!r}, "
                f"expected {expected_rx_burst_gap!r}"
            )
        if node.transport == "adb":
            if result.get("bluetooth") is not True:
                errors.append("Bluetooth is disabled")
            permissions = result.get("permissions", {})
            if permissions.get("scan") is not True:
                errors.append("BLE scan permission is missing")
            if permissions.get("advertise") is not True:
                errors.append("BLE advertise permission is missing")
            expected_build = self.config.get("android_build_id")
            actual_build = result.get("android_build_id", result.get("build_id"))
        else:
            expected_build = self.config.get("firmware_build_id")
            actual_build = result.get("firmware_build_id", result.get("build_id"))
        if expected_build and actual_build != expected_build:
            errors.append(f"build identity={actual_build!r}, expected {expected_build!r}")
        if result.get("scanner") is not True:
            errors.append("BLE scanner is not active")
        if spec is not None:
            topology = self._node_topology(node, spec.hypothesis)
            expected_active = topology.get("active", topology.get("role") != "OBSERVER")
            expected = {
                "session_id": self.manifest["session_id"],
                "mode": spec.mode,
                "role": topology["role"],
                "protocol_active": expected_active,
            }
            for key, value in expected.items():
                if result.get(key) != value:
                    errors.append(f"{key}={result.get(key)!r}, expected {value!r}")
            if result.get("gateway_enabled", False) is True or result.get("ack_enabled", False) is True:
                errors.append("gateway/ACK is enabled in the main experiment")
            device_trial_id = self._device_trial_id(spec)
            if require_active_trial and result.get("trial_id") != device_trial_id:
                errors.append(
                    f"trial_id={result.get('trial_id')!r}, expected {device_trial_id!r}"
                )
            if after_reset and result.get("trial_id") not in (None, ""):
                errors.append(f"trial_id was not cleared: {result.get('trial_id')!r}")
            if not after_reset:
                if result.get("advertising", result.get("advertiser")) is True:
                    errors.append("scheduler is advertising before trial start")
                if int(result.get("queue_size", 0) or 0) != 0:
                    errors.append("old relay queue is not empty")
                if result.get("packet_pending", False) is True:
                    errors.append("old packet is pending")
        if after_reset:
            if result.get("advertising", result.get("advertiser")) is True:
                errors.append("scheduler is still advertising")
            if int(result.get("queue_size", 0) or 0) != 0:
                errors.append("relay queue is not empty")
            if result.get("packet_pending", False) is True:
                errors.append("old packet is still pending")
            if result.get("quiet_period_complete", True) is not True:
                errors.append("quiet period is not complete")
        return errors

    def readiness(
        self,
        spec: TrialSpec | None = None,
        *,
        after_reset: bool = False,
        require_active_trial: bool = False,
    ) -> dict[str, dict[str, Any]]:
        results: dict[str, dict[str, Any]] = {}
        failures: list[str] = []
        for node in self.nodes:
            command_id = self._command_id(
                "ready", spec.trial_id if spec else "preflight", node.node_id
            )
            if node.transport == "serial":
                node.command(
                    "clock_sync",
                    {
                        "command_id": self._command_id("preflight-clock", node.node_id),
                        "wall_time_ms": time.time_ns() // 1_000_000,
                    },
                )
            result = node.command("readiness", {"command_id": command_id})
            if result.get("radio") is not None:
                self.manifest.setdefault("radio_readiness", {})[node.node_id] = result["radio"]
            results[node.node_id] = result
            reasons = self._readiness_errors(
                node,
                result,
                spec,
                after_reset,
                require_active_trial,
            )
            if reasons:
                failures.append(f"{node.node_id}: " + "; ".join(reasons))
        if failures:
            raise DeviceError("readiness failed: " + " | ".join(failures))
        return results

    def recover_interrupted_trials(
        self,
        readiness: dict[str, dict[str, Any]],
    ) -> None:
        stale_by_node = {
            node.node_id: str(readiness.get(node.node_id, {}).get("trial_id") or "").strip()
            for node in self.nodes
        }
        stale_by_node = {
            node_id: trial_id
            for node_id, trial_id in stale_by_node.items()
            if trial_id
        }
        if not stale_by_node:
            return

        recovered: list[dict[str, str]] = []
        for node in self.nodes:
            trial_id = stale_by_node.get(node.node_id)
            if not trial_id:
                continue
            if node.transport == "adb":
                finalized = node.command(
                    "finalize_trial",
                    {
                        "command_id": self._command_id(
                            "recover-finalize", trial_id, node.node_id
                        ),
                        "trial_id": trial_id,
                        "result": "INVALID",
                        "reason": "HOST_CONTROLLER_INTERRUPTED",
                    },
                )
                if finalized.get("ok") is not True:
                    raise DeviceError(
                        f"interrupted trial finalization failed: {node.node_id}: {finalized}"
                    )
            reset = node.command(
                "reset_trial",
                {
                    "command_id": self._command_id(
                        "recover-reset", trial_id, node.node_id
                    ),
                    "trial_id": trial_id,
                },
            )
            if reset.get("ok") is not True:
                raise DeviceError(
                    f"interrupted trial reset failed: {node.node_id}: {reset}"
                )
            recovered.append({"node_id": node.node_id, "trial_id": trial_id})

        self.sleep(float(self.config.get("quiet_period_seconds", 3)))
        verification = self.readiness()
        failures: list[str] = []
        for node in self.nodes:
            result = verification[node.node_id]
            if result.get("trial_id") not in (None, ""):
                failures.append(
                    f"{node.node_id}: trial_id was not cleared: {result.get('trial_id')!r}"
                )
            if result.get("advertising", result.get("advertiser")) is True:
                failures.append(f"{node.node_id}: scheduler is still advertising")
            if int(result.get("queue_size", 0) or 0) != 0:
                failures.append(f"{node.node_id}: relay queue is not empty")
            if result.get("packet_pending", False) is True:
                failures.append(f"{node.node_id}: old packet is still pending")
            if result.get("quiet_period_complete", True) is not True:
                failures.append(f"{node.node_id}: quiet period is not complete")
        if failures:
            raise DeviceError("interrupted trial recovery failed: " + " | ".join(failures))
        self.manifest["startup_recovery"] = {
            "recovered_at_ms": time.time_ns() // 1_000_000,
            "states": recovered,
        }
        self._save_manifest()

    def configure(self, spec: TrialSpec) -> None:
        for node in self.nodes:
            topology = self._node_topology(node, spec.hypothesis)
            arguments = {
                "command_id": self._command_id("cfg", spec.trial_id, node.node_id),
                "session_id": self.manifest["session_id"],
                "session_code": f"{spec.mode}-{spec.hypothesis}",
                "node_id": node.node_id,
                "role": topology["role"],
                "target_hop": int(spec.hypothesis[1:]),
                "hypothesis": spec.hypothesis,
                "observation_window_ms": int(self.config["observation_window_seconds"] * 1000),
                "mode": spec.mode,
                "build_id": self.config.get("session_label", self.config.get("build_id", "research")),
                "protocol_version": PROTOCOL_VERSION,
                "protocol_epoch_id": PROTOCOL_EPOCH_ID,
                "protocol_epoch_seconds": PROTOCOL_EPOCH_SECONDS,
                "manufacturer_id": 0xFFFF,
                "burst_duration_ms": 2000,
                "rx_burst_gap_ms": int(self.config["rx_burst_gap_ms"]),
                "node_layer": topology.get("node_layer", 0),
                "expected_hop_in": topology.get("expected_hop_in", 0),
                "hop_out": topology.get("hop_out", 0),
                "protocol_active": topology.get("active", topology["role"] != "OBSERVER"),
                "main_experiment": True,
            }
            if node.node_id in self.clock_offsets:
                arguments["clock_offset_ms"] = self.clock_offsets[node.node_id]
                arguments["clock_tolerance_ms"] = int(self.config.get("clock_tolerance_ms", 100))
            radio_mode = topology.get("radio_mode", self.config.get("radio_mode"))
            if radio_mode is not None:
                arguments["radio_mode"] = radio_mode
            result = node.command("configure_session", arguments)
            if result.get("ok") is not True:
                raise DeviceError(f"configuration failed: {node.node_id}: {result}")

    def synchronize_clocks(self, spec: TrialSpec) -> None:
        wall_ms = time.time_ns() // 1_000_000
        for node in self.nodes:
            if hasattr(node, "host_clock_offset_ms"):
                self.clock_offsets[node.node_id] = float(node.host_clock_offset_ms())
                continue
            result = node.command(
                "clock_sync",
                {
                    "command_id": self._command_id("clock", spec.trial_id, node.node_id),
                    "wall_time_ms": wall_ms,
                },
            )
            if result.get("ok") is not True:
                raise DeviceError(f"clock sync failed: {node.node_id}: {result}")
            self.clock_offsets[node.node_id] = 0.0
        self.manifest["clock_sync"] = {
            "valid": True,
            "offset_ms_by_node": self.clock_offsets,
            "captured_at_ms": wall_ms,
        }
        self._save_manifest()

    def _collect_trial_events(self, spec: TrialSpec) -> list[dict[str, Any]]:
        session_id = self.manifest["session_id"]
        device_trial_id = self._device_trial_id(spec)
        events: list[dict[str, Any]] = []
        discarded: list[dict[str, Any]] = []
        for node in self.nodes:
            node_events = node.collect_events(
                session_id=session_id,
                trial_id=device_trial_id,
            )
            accepted: list[dict[str, Any]] = []
            for event in node_events:
                if (
                    event.get("session_id") != session_id
                    or event.get("trial_id") != device_trial_id
                    or event.get("event_type") in (None, "")
                    or event.get("node_id", event.get("device_id")) != node.node_id
                ):
                    discarded.append({"transport_node": node.node_id, "event": event})
                    continue
                normalized = dict(event)
                if "message_key" in normalized:
                    normalized["message_key"] = canonical_message_key(normalized["message_key"])
                if "state_identity" in normalized:
                    normalized["state_identity"] = canonical_state_identity(
                        normalized["state_identity"]
                    )
                normalized["device_trial_id"] = device_trial_id
                normalized["trial_id"] = spec.trial_id
                normalized.setdefault("mode", spec.mode)
                normalized.setdefault("hypothesis", spec.hypothesis)
                normalized.setdefault("clock_sync_valid", True)
                normalized.setdefault("clock_offset_ms", self.clock_offsets.get(node.node_id, 0.0))
                accepted.append(normalized)
            write_jsonl(
                self.output_dir / "raw" / spec.trial_id / f"{node.node_id}.jsonl",
                accepted,
            )
            events.extend(accepted)
        if discarded:
            write_jsonl(
                self.output_dir / "diagnostics" / f"discarded-{spec.trial_id}.jsonl",
                discarded,
            )
        return events

    def _evaluate_events(
        self,
        spec: TrialSpec,
        events: list[dict[str, Any]],
        source_node: NodeTransport,
        message_key: str | None,
        record: dict[str, Any],
    ) -> tuple[str, list[str], dict[str, Any]]:
        invalid = {
            str(event.get("reason", "CONFIG_VIOLATION"))
            for event in events
            if event.get("event_type") == "EXPERIMENT_CONFIG_VIOLATION"
        }
        invalid.update(research_event_integrity_errors(events, record))
        metric_events = [
            event
            for event in events
            if event_within_observation_window(event, record)
        ]
        destination_ids = {
            node.node_id
            for node in self.nodes
            if self._node_topology(node, spec.hypothesis)["role"] == "DESTINATION"
        }
        expected_hop = int(spec.hypothesis[1:])
        if message_key in (None, ""):
            invalid.add("MESSAGE_KEY_MISSING")
        source_starts = [
            event
            for event in metric_events
            if event.get("event_type") == "SOURCE_FIRST_ADVERTISE_STARTED"
            and event.get("node_id", event.get("device_id")) == source_node.node_id
            and (message_key is None or event.get("message_key") == message_key)
        ]
        if not source_starts:
            invalid.add("SOURCE_FIRST_ADVERTISE_STARTED_MISSING")
        if message_key is None and source_starts:
            message_key = source_starts[0].get("message_key")
        destination_receives = [
            event
            for event in metric_events
            if event.get("event_type") == "DESTINATION_FIRST_VALID_RECEIVE"
            and event.get("node_id", event.get("device_id")) in destination_ids
            and event.get("message_key") == message_key
            and int(event.get("hop_in", event.get("hop_count", -1)) or -1) == expected_hop
        ]
        latency_ms: int | None = None
        if source_starts and destination_receives:
            source_times = [
                int(event.get("event_timestamp_ms", event.get("timestamp_ms", 0)))
                + int(round(float(event.get("clock_offset_ms", 0))))
                for event in source_starts
                if event.get("clock_sync_valid") is True
            ]
            destination_times = [
                int(event.get("event_timestamp_ms", event.get("timestamp_ms", 0)))
                + int(round(float(event.get("clock_offset_ms", 0))))
                for event in destination_receives
                if event.get("clock_sync_valid") is True
            ]
            if source_times and destination_times:
                latency_ms = min(destination_times) - min(source_times)
                observation_window_ms = int(
                    float(self.config["observation_window_seconds"]) * 1000
                )
                clock_tolerance_ms = int(self.config["clock_tolerance_ms"])
                maximum = observation_window_ms + clock_tolerance_ms
                if latency_ms < 0 or latency_ms > maximum:
                    invalid.add("E2E_LATENCY_OUT_OF_RANGE")
                    latency_ms = None
            else:
                invalid.add("CLOCK_SYNC_INVALID")
        result = "INVALID" if invalid else ("SUCCESS" if destination_receives else "FAILED_DELIVERY")
        return result, sorted(invalid), {
            "source_node_id": source_node.node_id,
            "destination_node_ids": sorted(destination_ids),
            "expected_hop_in": expected_hop,
            "message_key": message_key,
            "e2e_latency_ms": latency_ms,
            "events_total": len(events),
            "events_in_window": len(metric_events),
            "events_outside_window": len(events) - len(metric_events),
        }

    def _wait_for_source_start(
        self, source: NodeTransport, spec: TrialSpec, message_key: str | None
    ) -> int:
        deadline = time.monotonic() + 60
        poll = 0
        while time.monotonic() < deadline:
            poll += 1
            status = source.command("get_status", {
                "command_id": self._command_id("source-start", spec.trial_id, str(poll)),
            })
            if status.get("ok") is not True:
                raise DeviceError(f"source status failed: {status}")
            if (status.get("session_id") != self.manifest["session_id"]
                    or status.get("trial_id") != self._device_trial_id(spec)):
                raise DeviceError("SOURCE_START_STATUS_SCOPE_MISMATCH")
            value = status.get("source_first_advertise_started_at_ms")
            if value is not None:
                if canonical_message_key(status.get("source_first_advertise_message_key")) != message_key:
                    raise DeviceError("SOURCE_START_MESSAGE_KEY_MISMATCH")
                started_at = int(round(float(value) + self.clock_offsets.get(source.node_id, 0.0)))
                record = self.manifest["trials"][spec.trial_id]
                tolerance = int(self.config["clock_tolerance_ms"])
                if not (record["trigger_requested_at_ms"] - tolerance <= started_at
                        <= time.time_ns() // 1_000_000 + tolerance):
                    raise DeviceError("SOURCE_START_TIMESTAMP_INVALID")
                return started_at
            self.sleep(0.25)
        raise DeviceError("SOURCE_FIRST_ADVERTISE_STARTED_TIMEOUT")

    def run_trial(self, spec: TrialSpec) -> dict[str, Any]:
        previous = self.manifest["trials"].get(spec.trial_id)
        if previous and previous.get("terminal") is True:
            return previous
        if previous:
            previous.update(
                terminal=True,
                result="INVALID",
                invalid_reasons=["INTERRUPTED_ATTEMPT_NOT_REPLAYED"],
            )
            self._save_manifest()
            return previous
        device_trial_id = self._device_trial_id(spec)
        source_ids = [
            node.node_id
            for node in self.nodes
            if self._node_topology(node, spec.hypothesis)["role"] == "SOURCE"
            and self._node_topology(node, spec.hypothesis).get("active", True)
        ]
        destination_ids = [
            node.node_id
            for node in self.nodes
            if self._node_topology(node, spec.hypothesis)["role"] == "DESTINATION"
            and self._node_topology(node, spec.hypothesis).get("active", True)
        ]
        record: dict[str, Any] = {
            "trial_id": spec.trial_id,
            "device_trial_id": device_trial_id,
            "session_id": self.manifest["session_id"],
            "terminal": False,
            "mode": spec.mode,
            "hypothesis": spec.hypothesis,
            "attempt": spec.number,
            "source_node_id": source_ids[0],
            "destination_node_ids": sorted(destination_ids),
            "expected_hop_in": int(spec.hypothesis[1:]),
            "observation_window_ms": int(
                float(self.config["observation_window_seconds"]) * 1000
            ),
            "clock_tolerance_ms": int(self.config["clock_tolerance_ms"]),
            "rx_burst_gap_ms": int(self.config["rx_burst_gap_ms"]),
            "require_event_sequence": True,
            "require_complete_event_cycles": True,
            "require_trickle_timing_metadata": True,
            "observation_window_basis": "SOURCE_FIRST_ADVERTISE_STARTED",
            "event_sequence_node_ids": sorted(
                node.node_id for node in self.nodes if node.transport == "serial"
            ),
            "started_at_ms": time.time_ns() // 1_000_000,
            "config_fingerprint": self.config_fingerprint,
        }
        self.manifest["trials"][spec.trial_id] = record
        self._save_manifest()
        events: list[dict[str, Any]] = []
        try:
            self.synchronize_clocks(spec)
            self.configure(spec)
            self.readiness(spec)
            for node in self.nodes:
                result = node.command(
                    "start_trial",
                    {
                        "command_id": self._command_id("start", spec.trial_id, node.node_id),
                        "session_id": self.manifest["session_id"],
                        "trial_id": device_trial_id,
                        "trial_code": spec.trial_id,
                    },
                )
                if result.get("ok") is not True:
                    raise DeviceError(f"start failed: {node.node_id}: {result}")
            self.readiness(spec, require_active_trial=True)
            sources = [node for node in self.nodes if node.node_id == source_ids[0]]
            observation_window_ms = int(
                float(self.config["observation_window_seconds"]) * 1000
            )
            record["trigger_requested_at_ms"] = time.time_ns() // 1_000_000
            self._save_manifest()
            trigger = sources[0].command(
                "trigger_sos",
                {
                    "command_id": self._command_id("trigger", spec.trial_id),
                    "trial_id": device_trial_id,
                    "node_id": sources[0].node_id,
                    "latitude": self.config.get("latitude", 3.5952),
                    "longitude": self.config.get("longitude", 98.6722),
                },
            )
            if trigger.get("ok") is not True:
                raise DeviceError(f"trigger failed: {trigger}")
            record["message_key"] = canonical_message_key(trigger.get("message_key"))
            self._save_manifest()
            observation_started_at_ms = self._wait_for_source_start(
                sources[0], spec, record["message_key"]
            )
            record["observation_started_at_ms"] = observation_started_at_ms
            record["observation_ended_at_ms"] = observation_started_at_ms + observation_window_ms
            # Polling latency never moves the physical start or grants extra observation time.
            remaining_ms = record["observation_ended_at_ms"] - time.time_ns() // 1_000_000
            if remaining_ms <= 0:
                raise DeviceError("SOURCE_START_DISCOVERED_AFTER_OBSERVATION_WINDOW")
            observation_deadline = time.monotonic() + remaining_ms / 1000
            self._save_manifest()
            self.sleep(max(0.0, observation_deadline - time.monotonic()))
            record["observation_stop_command_at_ms"] = time.time_ns() // 1_000_000
            self._save_manifest()
            for node in self.nodes:
                node_observation_end_ms = record["observation_ended_at_ms"]
                if node.transport == "adb":
                    node_observation_end_ms -= int(
                        round(self.clock_offsets.get(node.node_id, 0.0))
                    )
                response = node.command(
                    "end_observation_window",
                    {
                        "command_id": self._command_id(
                            "window", spec.trial_id, node.node_id
                        ),
                        "trial_id": device_trial_id,
                        "observation_ended_at_ms": node_observation_end_ms,
                    },
                )
                if response.get("ok") is not True:
                    raise DeviceError(
                        f"end observation failed: {node.node_id}: {response}"
                    )
            events = self._collect_trial_events(spec)
            result_name, invalid_reasons, evidence = self._evaluate_events(
                spec,
                events,
                sources[0],
                record["message_key"],
                record,
            )
            record.update(
                terminal=True,
                result=result_name,
                invalid_reasons=invalid_reasons,
                event_count=len(events),
                evidence=evidence,
                ended_at_ms=time.time_ns() // 1_000_000,
            )
            for node in self.nodes:
                if node.transport != "adb":
                    continue
                node.command(
                    "finalize_trial",
                    {
                        "command_id": self._command_id("finalize", spec.trial_id, node.node_id),
                        "trial_id": device_trial_id,
                        "result": result_name,
                        "reason": ",".join(invalid_reasons),
                    },
                )
                record.setdefault("exports", {})[node.node_id] = node.command(
                    "export_trial",
                    {
                        "command_id": self._command_id("export", spec.trial_id, node.node_id),
                        "session_id": self.manifest["session_id"],
                        "trial_id": device_trial_id,
                    },
                )
        except Exception as error:
            record.update(
                terminal=True,
                result="INVALID",
                invalid_reasons=[str(error)],
                event_count=len(events),
                ended_at_ms=time.time_ns() // 1_000_000,
            )
        finally:
            reset_errors: list[str] = []
            for node in self.nodes:
                try:
                    response = node.command(
                        "reset_trial",
                        {
                            "command_id": self._command_id("reset", spec.trial_id, node.node_id),
                            "trial_id": device_trial_id,
                        },
                    )
                    if response.get("ok") is not True:
                        reset_errors.append(f"{node.node_id}: {response}")
                except Exception as error:
                    reset_errors.append(f"{node.node_id}: {error}")
            self.sleep(float(self.config.get("quiet_period_seconds", 3)))
            try:
                self.readiness(spec, after_reset=True)
                record["reset_verified"] = not reset_errors
            except Exception as error:
                reset_errors.append(str(error))
                record["reset_verified"] = False
            if reset_errors:
                record["reset_errors"] = reset_errors
                record["result"] = "INVALID"
                record["invalid_reasons"] = sorted(
                    set(record.get("invalid_reasons", [])) | {"RESET_OR_QUIET_PERIOD_FAILED"}
                )
            self._save_manifest()
        return record

    def _condition_counts(self) -> dict[tuple[str, str], Counter[str]]:
        counts = {
            (mode, hypothesis): Counter()
            for mode in self.config.get("modes", MODES)
            for hypothesis in self.config.get("hypotheses", HYPOTHESES)
        }
        for record in self.manifest["trials"].values():
            if record.get("terminal"):
                counts[(record["mode"], record["hypothesis"])][record.get("result", "INVALID")] += 1
        return counts

    def _append_replacement(self, mode: str, hypothesis: str) -> bool:
        attempts = [
            int(item["attempt"])
            for item in self.manifest["trial_order"]
            if item["mode"] == mode and item["hypothesis"] == hypothesis
        ]
        next_number = max(attempts, default=0) + 1
        if next_number > self.max_attempts:
            return False
        self.manifest["trial_order"].append(TrialSpec(mode, hypothesis, next_number).to_json())
        self._save_manifest()
        return True

    def batch_summary(self) -> dict[str, Any]:
        rows: list[dict[str, Any]] = []
        complete = True
        for (mode, hypothesis), count in sorted(self._condition_counts().items()):
            success = count["SUCCESS"]
            failed = count["FAILED_DELIVERY"]
            invalid = count["INVALID"]
            valid = success + failed
            attempts = valid + invalid
            reached = valid >= self.valid_target
            complete &= reached
            rows.append(
                {
                    "mode": mode,
                    "hypothesis": hypothesis,
                    "success": success,
                    "failed_delivery": failed,
                    "invalid": invalid,
                    "valid": valid,
                    "attempts": attempts,
                    "target": self.valid_target,
                    "complete": reached,
                }
            )
        return {"complete": complete, "conditions": rows}

    def _write_attempt_summary(self) -> None:
        rows = [
            {
                "trial_id": trial_id,
                "mode": record.get("mode"),
                "hypothesis": record.get("hypothesis"),
                "attempt": record.get("attempt"),
                "result": record.get("result"),
                "terminal": record.get("terminal"),
                "invalid_reasons": ";".join(record.get("invalid_reasons", [])),
            }
            for trial_id, record in sorted(self.manifest["trials"].items())
        ]
        path = self.output_dir / "attempt_summary.csv"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="") as output:
            fields = list(rows[0]) if rows else ["trial_id"]
            writer = csv.DictWriter(output, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

    def run(self, limit: int | None = None) -> list[dict[str, Any]]:
        readiness = self.readiness()
        self.recover_interrupted_trials(readiness)
        self._save_manifest()
        results: list[dict[str, Any]] = []
        index = 0
        executed = 0
        while index < len(self.manifest["trial_order"]):
            spec = TrialSpec.from_json(self.manifest["trial_order"][index])
            index += 1
            counts = self._condition_counts()[(spec.mode, spec.hypothesis)]
            if counts["SUCCESS"] + counts["FAILED_DELIVERY"] >= self.valid_target:
                continue
            result = self.run_trial(spec)
            results.append(result)
            executed += 1
            if result.get("result") == "INVALID":
                counts = self._condition_counts()[(spec.mode, spec.hypothesis)]
                if counts["SUCCESS"] + counts["FAILED_DELIVERY"] < self.valid_target:
                    self._append_replacement(spec.mode, spec.hypothesis)
            if limit is not None and executed >= limit:
                break
        summary = self.batch_summary()
        self.manifest["summary"] = summary
        self._save_manifest()
        self._write_attempt_summary()
        if limit is None and not summary["complete"]:
            raise BatchIncompleteError(summary)
        return results

    def smoke_report(self) -> dict[str, Any]:
        from .log_merge import read_json_events, summarize_trial

        conditions: list[dict[str, Any]] = []
        records = list(self.manifest["trials"].values())
        for mode, hypothesis in sorted((mode, hypothesis) for mode in MODES for hypothesis in HYPOTHESES):
            matching = [
                record
                for record in records
                if record.get("mode") == mode and record.get("hypothesis") == hypothesis
            ]
            record = matching[0] if matching else {}
            trial_id = record.get("trial_id", "")
            paths = list((self.output_dir / "raw" / trial_id).glob("*.jsonl")) if trial_id else []
            events = read_json_events(paths)
            summary = summarize_trial(trial_id, events, record)
            event_types = {
                event.get("event_type")
                for event in events
                if event_within_observation_window(event, record)
            }
            missing: list[str] = []
            result = record.get("result")
            if result == "INVALID":
                reasons = record.get("invalid_reasons") or ["UNSPECIFIED"]
                missing.extend(f"invalid trial: {reason}" for reason in reasons)
            elif result != "SUCCESS":
                missing.append("successful destination delivery")
            if "SOURCE_FIRST_ADVERTISE_STARTED" not in event_types:
                missing.append("SOURCE_FIRST_ADVERTISE_STARTED")
            if "DESTINATION_FIRST_VALID_RECEIVE" not in event_types:
                missing.append("DESTINATION_FIRST_VALID_RECEIVE")
            if summary.get("e2e_latency_ms") is None:
                missing.append("valid end-to-end latency")
            if mode == "trickle" and hypothesis in {"H2", "H3"}:
                if "TRICKLE_CONSISTENT_HEARD" not in event_types:
                    missing.append("TRICKLE_CONSISTENT_HEARD")
                if "TRICKLE_TX_SUPPRESSED" not in event_types:
                    missing.append("TRICKLE_TX_SUPPRESSED")
            if mode == "basic_flooding" and "TRICKLE_TX_SUPPRESSED" in event_types:
                missing.append("absence of TRICKLE_TX_SUPPRESSED")
            if record.get("reset_verified") is not True:
                missing.append("reset/quiet-period verification")
            conditions.append(
                {
                    "mode": mode,
                    "hypothesis": hypothesis,
                    "trial_id": trial_id,
                    "result": result or "MISSING",
                    "passed": not missing,
                    "missing_evidence": ";".join(missing),
                }
            )
        report = {
            "passed": len(conditions) == 6 and all(item["passed"] for item in conditions),
            "config_fingerprint": self.config_fingerprint,
            "session_id": self.manifest["session_id"],
            "conditions": conditions,
        }
        self.output_dir.mkdir(parents=True, exist_ok=True)
        (self.output_dir / "smoke_report.json").write_text(
            json.dumps(report, indent=2, sort_keys=True), encoding="utf-8"
        )
        with (self.output_dir / "smoke_report.csv").open("w", encoding="utf-8", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=list(conditions[0]))
            writer.writeheader()
            writer.writerows(conditions)
        return report
