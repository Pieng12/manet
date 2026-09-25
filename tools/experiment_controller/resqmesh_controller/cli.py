from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from .controller import ExperimentController
from .devices import AdbNode, NodeTransport, SerialNode, discover_adb, discover_serial
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
    if args.command == "smoke":
        config["trials_per_condition"] = 1
    nodes = build_nodes(config)
    controller = ExperimentController(config, nodes, args.output)
    try:
        if args.command == "readiness":
            print(json.dumps(controller.readiness(), indent=2))
        else:
            limit = args.limit if args.command == "run" else None
            print(json.dumps(controller.run(limit=limit), indent=2))
    finally:
        for node in nodes:
            node.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
