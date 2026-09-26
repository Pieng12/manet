from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

from .config import ConfigError, research_fingerprint, validate_config
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


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


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
    adb_records = {item["serial"]: item for item in discover_adb()}
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
    subparsers.add_parser("discover")
    for name in ("readiness", "smoke", "run"):
        command = subparsers.add_parser(name)
        command.add_argument("--config", type=Path, required=True)
        command.add_argument("--output", type=Path, default=Path("experiment_output"))
        if name == "run":
            command.add_argument("--limit", type=int)
            command.add_argument("--force-without-smoke", action="store_true")
    merge = subparsers.add_parser("merge")
    merge.add_argument("--input", type=Path, required=True)
    merge.add_argument("--output", type=Path, required=True)
    merge.add_argument("--manifest", type=Path)
    args = parser.parse_args()

    if args.command == "discover":
        print(json.dumps({"adb": discover_adb(), "serial": discover_serial()}, indent=2))
        return 0
    if args.command == "merge":
        print(json.dumps(merge_directory(args.input, args.output, args.manifest), indent=2))
        return 0

    config = load_config(args.config)
    try:
        validate_config(config)
    except ConfigError as error:
        print(json.dumps({"ok": False, "error": str(error)}, indent=2))
        return 2
    if args.command == "smoke":
        config["valid_trials_per_condition"] = 1
        config["max_attempts_per_condition"] = 1
        config["trial_order"] = "blocked"
        run_output = args.output / "smoke_run"
    else:
        run_output = args.output
    if args.command == "run" and not args.force_without_smoke:
        smoke_path = args.output / "smoke_report.json"
        if not smoke_path.exists():
            print(json.dumps({"ok": False, "error": "smoke_report.json is required before batch"}, indent=2))
            return 3
        smoke = json.loads(smoke_path.read_text(encoding="utf-8"))
        if smoke.get("passed") is not True or smoke.get("config_fingerprint") != research_fingerprint(config):
            print(json.dumps({"ok": False, "error": "smoke report failed or does not match build/config/topology"}, indent=2))
            return 3
    try:
        validate_discovered_nodes(config)
    except (DeviceError, ValueError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, indent=2))
        return 2
    nodes = build_nodes(config)
    controller = ExperimentController(config, nodes, run_output)
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
                print(json.dumps(report, indent=2))
                return 0 if report["passed"] else 5
            print(json.dumps({"results": results, "summary": controller.batch_summary()}, indent=2))
    finally:
        for node in nodes:
            node.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
