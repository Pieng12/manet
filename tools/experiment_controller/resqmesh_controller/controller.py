from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from . import PROTOCOL_EPOCH_ID, PROTOCOL_EPOCH_SECONDS
from .devices import DeviceError, NodeTransport, write_jsonl


@dataclass(frozen=True)
class TrialSpec:
    mode: str
    hypothesis: str
    number: int

    @property
    def trial_id(self) -> str:
        return f"{self.mode}-{self.hypothesis}-T{self.number:03d}"


def build_plan(config: dict[str, Any]) -> list[TrialSpec]:
    return [
        TrialSpec(mode, hypothesis, number)
        for mode in config.get("modes", ["trickle", "basic_flooding"])
        for hypothesis in config.get("hypotheses", ["H1", "H2", "H3"])
        for number in range(1, int(config.get("trials_per_condition", 15)) + 1)
    ]


class ExperimentController:
    def __init__(
        self,
        config: dict[str, Any],
        nodes: list[NodeTransport],
        output_dir: Path,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.config = config
        self.nodes = nodes
        self.output_dir = output_dir
        self.sleep = sleep
        self.manifest_path = output_dir / "manifest.json"
        self.manifest = self._load_manifest()
        self.clock_offsets: dict[str, float] = {}

    def _load_manifest(self) -> dict[str, Any]:
        if self.manifest_path.exists():
            return json.loads(self.manifest_path.read_text(encoding="utf-8"))
        return {
            "session_id": self.config.get("session_id", f"session-{uuid.uuid4().hex[:8]}"),
            "epoch_id": PROTOCOL_EPOCH_ID,
            "trials": {},
        }

    def _save_manifest(self) -> None:
        self.output_dir.mkdir(parents=True, exist_ok=True)
        temporary = self.manifest_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.manifest, indent=2, sort_keys=True), encoding="utf-8")
        os.replace(temporary, self.manifest_path)

    def readiness(self) -> dict[str, dict[str, Any]]:
        results: dict[str, dict[str, Any]] = {}
        for node in self.nodes:
            if node.__class__.__name__ != "AdbNode":
                node.command(
                    "clock_sync",
                    {
                        "command_id": f"preflight-clock-{node.node_id}",
                        "wall_time_ms": time.time_ns() // 1_000_000,
                    },
                )
            result = node.command("readiness", {})
            results[node.node_id] = result
            epoch = result.get("protocol_epoch", result)
            valid = epoch.get("valid", epoch.get("epoch_valid"))
            epoch_id = epoch.get("epoch_id")
            bluetooth = result.get("bluetooth", True)
            permissions = result.get("permissions", {"scan": True, "advertise": True})
            if (
                result.get("ok") is not True
                or valid is not True
                or epoch_id != PROTOCOL_EPOCH_ID
                or bluetooth is not True
                or not all(permissions.values())
            ):
                raise DeviceError(f"node not ready: {node.node_id}: {result}")
        return results

    def _node_topology(self, node: NodeTransport, hypothesis: str) -> dict[str, Any]:
        configured = next(item for item in self.config["nodes"] if item["node_id"] == node.node_id)
        topology = configured.get("topology", {}).get(hypothesis, {})
        return {**configured, **topology}

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
                "build_id": self.config["build_id"],
                "protocol_epoch_id": PROTOCOL_EPOCH_ID,
                "protocol_epoch_seconds": PROTOCOL_EPOCH_SECONDS,
                "manufacturer_id": 0xFFFF,
                "burst_duration_ms": 2000,
                "node_layer": topology.get("node_layer", 0),
                "expected_hop_in": topology.get("expected_hop_in", 0),
                "hop_out": topology.get("hop_out", 0),
                "protocol_active": topology.get("active", True),
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

    def run_trial(self, spec: TrialSpec) -> dict[str, Any]:
        previous = self.manifest["trials"].get(spec.trial_id)
        if previous and previous.get("terminal") is True:
            return previous
        record = {"terminal": False, "mode": spec.mode, "hypothesis": spec.hypothesis}
        self.manifest["trials"][spec.trial_id] = record
        self._save_manifest()
        try:
            self.synchronize_clocks(spec)
            self.configure(spec)
            self.readiness()
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
            sources = [node for node in self.nodes if self._node_topology(node, spec.hypothesis)["role"] == "SOURCE"]
            if len(sources) != 1:
                raise DeviceError(f"expected exactly one SOURCE, found {len(sources)}")
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
            self.sleep(float(self.config["observation_window_seconds"]))
            events: list[dict[str, Any]] = []
            for node in self.nodes:
                node_events = node.collect_events()
                for event in node_events:
                    event.setdefault("node_id", node.node_id)
                    event.setdefault("trial_id", spec.trial_id)
                    event.setdefault("mode", spec.mode)
                    event.setdefault("hypothesis", spec.hypothesis)
                    event.setdefault("clock_sync_valid", True)
                    event.setdefault("clock_offset_ms", self.clock_offsets.get(node.node_id, 0.0))
                write_jsonl(self.output_dir / "raw" / spec.trial_id / f"{node.node_id}.jsonl", node_events)
                events.extend(node_events)
            invalid_reasons = sorted(
                {event.get("reason", "CONFIG_VIOLATION") for event in events if event.get("event_type") == "EXPERIMENT_CONFIG_VIOLATION"}
            )
            delivered = any(event.get("event_type") == "DESTINATION_FIRST_VALID_RECEIVE" for event in events)
            result_name = "INVALID" if invalid_reasons else ("SUCCESS" if delivered else "FAILED_DELIVERY")
            record.update(
                terminal=True,
                result=result_name,
                invalid_reasons=invalid_reasons,
                event_count=len(events),
            )
            for node in self.nodes:
                if node.__class__.__name__ != "AdbNode":
                    continue
                node.command(
                    "end_observation_window",
                    {"command_id": f"window-{spec.trial_id}-{node.node_id}", "trial_id": spec.trial_id},
                )
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
            record.update(terminal=True, result="INVALID", invalid_reasons=[str(error)])
        finally:
            for node in self.nodes:
                try:
                    node.command(
                        "reset_trial",
                        {"command_id": f"reset-{spec.trial_id}-{node.node_id}", "trial_id": spec.trial_id},
                    )
                except Exception as error:
                    record.setdefault("reset_errors", []).append(f"{node.node_id}: {error}")
            self.sleep(float(self.config.get("quiet_period_seconds", 3)))
            self._save_manifest()
        return record

    def run(self, limit: int | None = None) -> list[dict[str, Any]]:
        self.readiness()
        plan = build_plan(self.config)
        if limit is not None:
            plan = plan[:limit]
        return [self.run_trial(spec) for spec in plan]
