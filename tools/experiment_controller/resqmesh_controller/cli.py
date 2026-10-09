from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

from .config import ConfigError, smoke_matches_config, validate_config
from .controller import BatchIncompleteError, ExperimentController
from .devices import (
    AdbNode,
    DeviceError,
    NodeTransport,
    SerialNode,
    discover_adb,
    discover_serial,
)
from .log_merge import merge_directory
from .neighbor_testbed import evidence_profile


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def build_nodes(config: dict[str, Any]) -> list[NodeTransport]:
    nodes: list[NodeTransport] = []
    for item in config["nodes"]:
        role = item.get("role", "OBSERVER")
        if item["transport"] == "adb":
            nodes.append(AdbNode(item["node_id"], role, item["serial"]))
        elif item["transport"] == "serial":
            nodes.append(
                SerialNode(
                    item["node_id"],
                    role,
                    item["port"],
                    int(item.get("baudrate", 115200)),
                )
            )
        else:
            raise ValueError(f"unknown transport: {item['transport']}")
    return nodes


def validate_discovered_nodes(config: dict[str, Any]) -> None:
    adb_records = ({item["serial"]: item for item in discover_adb()}
                   if any(n["transport"] == "adb" for n in config["nodes"]) else {})
    serial_records = {str(item["port"]).upper(): item for item in discover_serial()}
    errors: list[str] = []
    for item in config["nodes"]:
        if item["transport"] == "adb":
            record = adb_records.get(str(item["serial"]))
            if record is None:
                errors.append(f"ADB device not found: {item['serial']}")
            elif record.get("status") != "device":
                errors.append(f"ADB device {item['serial']} status={record.get('status')}")
        elif item["transport"] == "serial":
            record = serial_records.get(str(item["port"]).upper())
            if record is None:
                errors.append(f"serial port not found: {item['port']}")
            elif record.get("excluded_bluetooth_serial") is True:
                errors.append(f"{item['port']} is Standard Serial over Bluetooth link")
    if errors:
        raise ValueError("; ".join(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description="ResQMesh physical experiment controller")
    subparsers = parser.add_subparsers(dest="command", required=True)
    discovery = subparsers.add_parser("discover")
    discovery.add_argument("--serial-only", action="store_true", help="Do not invoke ADB")
    for name in ("plan", "readiness", "smoke", "run"):
        command = subparsers.add_parser(name)
        command.add_argument("--config", type=Path, required=True)
        command.add_argument("--output", type=Path, default=Path("experiment_output"))
        if name == "run":
            command.add_argument("--limit", type=int)
            command.add_argument("--force-without-smoke", action="store_true")
            command.add_argument("--smoke-report", type=Path, help="Validated smoke report from a separate output folder")
    merge = subparsers.add_parser("merge")
    merge.add_argument("--input", type=Path, required=True)
    merge.add_argument("--output", type=Path, required=True)
    merge.add_argument("--manifest", type=Path)
    validator = subparsers.add_parser("validate-neighbor")
    validator.add_argument("--input", type=Path, required=True)
    validator.add_argument("--output", type=Path, required=True)
    validator.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()

    if args.command == "discover":
        print(json.dumps({"adb": [] if args.serial_only else discover_adb(), "serial": discover_serial()}, indent=2))
        return 0
    if args.command == "merge":
        print(json.dumps(merge_directory(args.input, args.output, args.manifest), indent=2))
        return 0
    if args.command == "validate-neighbor":
        from .neighbor_validation import validate_directory
        result = validate_directory(args.input, args.output, args.manifest)
        print(json.dumps(result, indent=2))
        return 2 if result["counts"]["FAIL"] else 3 if result["counts"]["INCONCLUSIVE"] or not result["checks"] else 0

    try:
        config = load_config(args.config)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "config": str(args.config.resolve()),
                          "error": f"Konfigurasi tidak dapat dibaca: {error}",
                          "instruction": "Buat konfigurasi lokal dari contoh yang sesuai, lalu isi COM dan build ID sebelum plan/readiness."}))
        return 2
    controller_type = ExperimentController
    if config.get("transport_profile") == "neighbor_graph_v1":
        from .neighbor_experiment import NeighborExperimentController
        controller_type = NeighborExperimentController
    try:
        validate_config(config)
    except ConfigError as error:
        print(json.dumps({"ok": False, "error": str(error)}, indent=2))
        return 2
    if args.command == "plan":
        controller = controller_type(config, [], args.output)
        controller._save_manifest()
        print(json.dumps({"manifest": str(controller.manifest_path),
                          "planned_trials": len(controller.manifest["trial_order"]),
                          "target_valid_trials": controller.manifest["target_valid_trials"],
                          "measured_trials": 0}, indent=2))
        return 0
    if args.command == "smoke":
        # Different command/trial IDs from the main run, even with the same fingerprint.
        config = {**config, "session_id": f"{config.get('session_id', 'three-methods')}-smoke"}
        config["valid_trials_per_condition"] = 1
        config["max_attempts_per_condition"] = 1
        config["trial_order"] = "balanced_randomized" if config.get("transport_profile") == "neighbor_graph_v1" else "blocked"
        run_output = args.output / "smoke_run"
    else:
        run_output = args.output
    if args.command == "run" and not args.force_without_smoke:
        smoke_path = args.smoke_report or args.output / "smoke_report.json"
        if not smoke_path.exists():
            print(json.dumps({"ok": False, "error": "smoke_report.json is required before batch"}, indent=2))
            return 3
        try:
            smoke = load_config(smoke_path)
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            print(json.dumps({"ok": False, "error": f"Smoke report tidak dapat dibaca: {error}"}))
            return 3
        if not smoke_matches_config(smoke, config):
            print(json.dumps({"ok": False, "error": "smoke report failed or does not match build/config/topology"}, indent=2))
            return 3
    try:
        validate_discovered_nodes(config)
    except (DeviceError, ValueError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, indent=2))
        return 2
    nodes = build_nodes(config)
    controller = controller_type(config, nodes, run_output)
    try:
        if args.command == "readiness":
            print(json.dumps(controller.readiness(), indent=2))
        else:
            try:
                limit = args.limit if args.command == "run" else None
                results = controller.run(limit=limit)
            except BatchIncompleteError as error:
                if args.command != "smoke":
                    print(json.dumps({"ok": False, "summary": error.summary}, indent=2))
                    return 4
                results = list(controller.manifest.get("trials", {}).values())
            if args.command == "smoke":
                report = controller.smoke_report()
                args.output.mkdir(parents=True, exist_ok=True)
                shutil.copy2(run_output / "smoke_report.json", args.output / "smoke_report.json")
                shutil.copy2(run_output / "smoke_report.csv", args.output / "smoke_report.csv")
                merge_directory(
                    run_output / "raw",
                    args.output / "smoke_merged",
                    run_output / "manifest.json",
                )
                print(json.dumps(report, indent=2))
                return 0 if report["passed"] else 5
            merge_directory(
                run_output / "raw",
                run_output / "merged",
                run_output / "manifest.json",
            )
            print(json.dumps({"results": results, "summary": controller.batch_summary()}, indent=2))
    except (KeyboardInterrupt, DeviceError, OSError) as error:
        if not evidence_profile(config):
            raise
        controller._save_manifest()
        controller._write_attempt_summary()
        partial_export_error = None
        if (run_output / "raw").exists():
            try:
                merge_directory(run_output / "raw", run_output / "partial_merged", run_output / "manifest.json")
            except Exception as export_error:
                partial_export_error = str(export_error)
        print(json.dumps({"ok": False, "error": "USER_INTERRUPTED" if isinstance(error, KeyboardInterrupt) else str(error),
                          "manifest": str(controller.manifest_path),
                          "partial_export_error": partial_export_error,
                          "instruction": "Pastikan advertising ESP berhenti; jika cleanup belum terkonfirmasi, matikan ESP sebelum mengulang."}))
        return 130 if isinstance(error, KeyboardInterrupt) else 2
    finally:
        for node in nodes:
            node.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
