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
            if require_active_trial and result.get("trial_id") != spec.trial_id:
                errors.append(
                    f"trial_id={result.get('trial_id')!r}, expected {spec.trial_id!r}"
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
            command_id = f"ready-{spec.trial_id if spec else 'preflight'}-{node.node_id}"
            if node.transport == "serial":
                node.command(
                    "clock_sync",
                    {
                        "command_id": f"preflight-clock-{node.node_id}",
                        "wall_time_ms": time.time_ns() // 1_000_000,
                    },
                )
            result = node.command("readiness", {"command_id": command_id})
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

    def configure(self, spec: TrialSpec) -> None:
        for node in self.nodes:
            topology = self._node_topology(node, spec.hypothesis)
            arguments = {
                "command_id": f"cfg-{spec.trial_id}-{node.node_id}",
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
                {"command_id": f"clock-{spec.trial_id}-{node.node_id}", "wall_time_ms": wall_ms},
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
        events: list[dict[str, Any]] = []
        discarded: list[dict[str, Any]] = []
        for node in self.nodes:
            node_events = node.collect_events(session_id=session_id, trial_id=spec.trial_id)
            accepted: list[dict[str, Any]] = []
            for event in node_events:
                if (
                    event.get("session_id") != session_id
                    or event.get("trial_id") != spec.trial_id
                    or event.get("event_type") in (None, "")
                    or event.get("node_id", event.get("device_id")) != node.node_id
                ):
                    discarded.append({"transport_node": node.node_id, "event": event})
                    continue
                normalized = dict(event)
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
    ) -> tuple[str, list[str], dict[str, Any]]:
        invalid = {
            str(event.get("reason", "CONFIG_VIOLATION"))
            for event in events
            if event.get("event_type") == "EXPERIMENT_CONFIG_VIOLATION"
        }
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
            for event in events
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
            for event in events
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
        }

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
                        "command_id": f"start-{spec.trial_id}-{node.node_id}",
                        "session_id": self.manifest["session_id"],
                        "trial_id": spec.trial_id,
                        "trial_code": spec.trial_id,
                    },
                )
                if result.get("ok") is not True:
                    raise DeviceError(f"start failed: {node.node_id}: {result}")
            self.readiness(spec, require_active_trial=True)
            sources = [node for node in self.nodes if node.node_id == source_ids[0]]
            trigger = sources[0].command(
                "trigger_sos",
                {
                    "command_id": f"trigger-{spec.trial_id}",
                    "trial_id": spec.trial_id,
                    "node_id": sources[0].node_id,
                    "latitude": self.config.get("latitude", 3.5952),
                    "longitude": self.config.get("longitude", 98.6722),
                },
            )
            if trigger.get("ok") is not True:
                raise DeviceError(f"trigger failed: {trigger}")
            record["message_key"] = trigger.get("message_key")
            self._save_manifest()
            self.sleep(float(self.config["observation_window_seconds"]))
            for node in self.nodes:
                if node.transport == "adb":
                    node.command(
                        "end_observation_window",
                        {"command_id": f"window-{spec.trial_id}-{node.node_id}", "trial_id": spec.trial_id},
                    )
            events = self._collect_trial_events(spec)
            result_name, invalid_reasons, evidence = self._evaluate_events(
                spec, events, sources[0], trigger.get("message_key")
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
                        "command_id": f"finalize-{spec.trial_id}-{node.node_id}",
                        "trial_id": spec.trial_id,
                        "result": result_name,
                        "reason": ";".join(invalid_reasons),
                    },
                )
                record.setdefault("exports", {})[node.node_id] = node.command(
                    "export_trial",
                    {
                        "command_id": f"export-{spec.trial_id}-{node.node_id}",
                        "session_id": self.manifest["session_id"],
                        "trial_id": spec.trial_id,
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
                        {"command_id": f"reset-{spec.trial_id}-{node.node_id}", "trial_id": spec.trial_id},
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
        self.readiness()
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
            event_types = {event.get("event_type") for event in events}
            missing: list[str] = []
            if record.get("result") != "SUCCESS":
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
                    "result": record.get("result", "MISSING"),
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
