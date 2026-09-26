from __future__ import annotations

import hashlib
import json
import re
from typing import Any


MODES = ("trickle", "basic_flooding")
HYPOTHESES = ("H1", "H2", "H3")
ROLES = {"SOURCE", "RELAY", "DESTINATION", "OBSERVER"}
PHYSICAL_NODE_IDS = {
    "android-source",
    "esp-r1a",
    "esp-r1b",
    "esp-r2a",
    "esp-r2b",
    "esp-destination",
}
BUILD_ID_PATTERN = re.compile(r"^[0-9a-fA-F]{12,40}$")
PLACEHOLDER_BUILD_IDS = {
    "",
    "unknown",
    "dev",
    "development",
    "esp32c3-dev",
    "placeholder",
    "<git_sha_12>",
}


class ConfigError(ValueError):
    pass


def _active(topology: dict[str, Any]) -> bool:
    return topology.get("active", topology.get("role") != "OBSERVER") is True


def _valid_research_build_id(value: Any) -> bool:
    build_id = str(value or "").strip()
    return (
        build_id.lower() not in PLACEHOLDER_BUILD_IDS
        and BUILD_ID_PATTERN.fullmatch(build_id) is not None
    )


def validate_config(config: dict[str, Any]) -> None:
    errors: list[str] = []
    nodes = config.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        raise ConfigError("nodes must be a non-empty list")

    node_ids = [str(node.get("node_id", "")).strip() for node in nodes]
    if any(not node_id for node_id in node_ids):
        errors.append("every node requires a non-empty node_id")
    if len(node_ids) != len(set(node_ids)):
        errors.append("duplicate node_id")

    serials = [
        str(node.get("serial", "")).strip()
        for node in nodes
        if node.get("transport") == "adb"
    ]
    ports = [
        str(node.get("port", "")).strip().upper()
        for node in nodes
        if node.get("transport") == "serial"
    ]
    if any(not value for value in serials):
        errors.append("every ADB node requires a serial")
    if any(not value for value in ports):
        errors.append("every serial node requires a port")
    if len(serials) != len(set(serials)):
        errors.append("duplicate ADB serial")
    if len(ports) != len(set(ports)):
        errors.append("duplicate COM port")

    modes = config.get("modes", list(MODES))
    hypotheses = config.get("hypotheses", list(HYPOTHESES))
    if set(modes) != set(MODES):
        errors.append("modes must contain trickle and basic_flooding")
    if set(hypotheses) != set(HYPOTHESES):
        errors.append("topology must contain H1, H2, and H3")
    if config.get("testbed_profile") == "android_plus_five_esp32" and set(node_ids) != PHYSICAL_NODE_IDS:
        missing = sorted(PHYSICAL_NODE_IDS - set(node_ids))
        extra = sorted(set(node_ids) - PHYSICAL_NODE_IDS)
        errors.append(f"five-ESP32 profile mismatch; missing={missing}, extra={extra}")

    for hypothesis in HYPOTHESES:
        target_hop = int(hypothesis[1:])
        topology_by_node: dict[str, dict[str, Any]] = {}
        for node in nodes:
            topology = node.get("topology", {}).get(hypothesis)
            if not isinstance(topology, dict):
                errors.append(f"{node.get('node_id')} missing topology {hypothesis}")
                continue
            topology_by_node[str(node.get("node_id"))] = topology
            role = str(topology.get("role", "")).upper()
            if role not in ROLES:
                errors.append(f"{node.get('node_id')} {hypothesis} has unknown role {role!r}")
                continue
            active = _active(topology)
            if not active and (role != "OBSERVER" or topology.get("hop_out") not in (None, 0)):
                errors.append(f"inactive node {node.get('node_id')} may not send in {hypothesis}")
            if role == "DESTINATION" and topology.get("hop_out") not in (None, 0):
                errors.append(f"destination {node.get('node_id')} may not relay in {hypothesis}")
            if active and role == "RELAY":
                hop_in = topology.get("expected_hop_in")
                hop_out = topology.get("hop_out")
                if not isinstance(hop_in, int) or hop_out != hop_in + 1:
                    errors.append(
                        f"{node.get('node_id')} {hypothesis} requires hop_out=expected_hop_in+1"
                    )

        active_nodes = [
            (node, topology_by_node.get(str(node.get("node_id")), {}))
            for node in nodes
            if _active(topology_by_node.get(str(node.get("node_id")), {}))
        ]
        sources = [item for item in active_nodes if item[1].get("role") == "SOURCE"]
        destinations = [item for item in active_nodes if item[1].get("role") == "DESTINATION"]
        if len(sources) != 1:
            errors.append(f"{hypothesis} requires exactly one active source")
        if not destinations:
            errors.append(f"{hypothesis} requires an active destination")
        for node, topology in destinations:
            if topology.get("expected_hop_in") != target_hop:
                errors.append(
                    f"{node.get('node_id')} {hypothesis} expected_hop_in must be {target_hop}"
                )

        relays = [topology for _, topology in active_nodes if topology.get("role") == "RELAY"]
        for hop in range(1, target_hop):
            if not any(
                relay.get("expected_hop_in") == hop and relay.get("hop_out") == hop + 1
                for relay in relays
            ):
                errors.append(f"{hypothesis} relay chain is missing hop {hop}->{hop + 1}")
        for relay in relays:
            hop_in = relay.get("expected_hop_in")
            hop_out = relay.get("hop_out")
            upstream = hop_in == 1 or any(other.get("hop_out") == hop_in for other in relays)
            downstream = any(other.get("expected_hop_in") == hop_out for other in relays) or any(
                destination.get("expected_hop_in") == hop_out for _, destination in destinations
            )
            if not upstream or not downstream:
                errors.append(
                    f"{hypothesis} relay expected_hop_in={hop_in} has no complete upstream/downstream"
                )

    valid_target = int(config.get("valid_trials_per_condition", config.get("trials_per_condition", 15)))
    max_attempts = int(config.get("max_attempts_per_condition", max(45, valid_target)))
    if valid_target <= 0:
        errors.append("valid_trials_per_condition must be positive")
    if max_attempts < valid_target:
        errors.append("max_attempts_per_condition must be >= valid trial target")
    if config.get("trial_order", "blocked") not in {"blocked", "randomized"}:
        errors.append("trial_order must be blocked or randomized")
    if config.get("gateway_enabled") is True or config.get("ack_enabled") is True:
        errors.append("gateway and ACK must be disabled for the main experiment")

    android_build_id = config.get("android_build_id")
    firmware_build_id = config.get("firmware_build_id")
    if not _valid_research_build_id(android_build_id):
        errors.append("android_build_id must be a Git commit SHA of at least 12 hex characters")
    if not _valid_research_build_id(firmware_build_id):
        errors.append("firmware_build_id must be a Git commit SHA of at least 12 hex characters")
    if (
        _valid_research_build_id(android_build_id)
        and _valid_research_build_id(firmware_build_id)
        and android_build_id != firmware_build_id
    ):
        errors.append("android_build_id and firmware_build_id must identify the same commit")

    try:
        observation_window = float(config.get("observation_window_seconds", 0))
    except (TypeError, ValueError):
        observation_window = 0
    if observation_window <= 0:
        errors.append("observation_window_seconds must be positive")
    try:
        clock_tolerance = int(config.get("clock_tolerance_ms", -1))
    except (TypeError, ValueError):
        clock_tolerance = -1
    if clock_tolerance < 0:
        errors.append("clock_tolerance_ms must be zero or positive")

    if errors:
        raise ConfigError("; ".join(errors))


def research_fingerprint(config: dict[str, Any]) -> str:
    relevant = {
        "android_build_id": config.get("android_build_id", config.get("build_id")),
        "firmware_build_id": config.get("firmware_build_id"),
        "protocol_version": config.get("protocol_version", "resqmesh-ble17-v1"),
        "modes": config.get("modes", list(MODES)),
        "hypotheses": config.get("hypotheses", list(HYPOTHESES)),
        "nodes": config.get("nodes", []),
        "observation_window_seconds": config.get("observation_window_seconds"),
        "quiet_period_seconds": config.get("quiet_period_seconds"),
        "clock_tolerance_ms": config.get("clock_tolerance_ms"),
        "gateway_enabled": config.get("gateway_enabled", False),
        "ack_enabled": config.get("ack_enabled", False),
        "latitude": config.get("latitude"),
        "longitude": config.get("longitude"),
        "rx_burst_gap_ms": config.get("rx_burst_gap_ms"),
    }
    encoded = json.dumps(relevant, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def smoke_matches_config(smoke_report: dict[str, Any], config: dict[str, Any]) -> bool:
    return (
        smoke_report.get("passed") is True
        and smoke_report.get("config_fingerprint") == research_fingerprint(config)
    )
