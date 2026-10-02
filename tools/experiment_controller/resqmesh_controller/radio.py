from __future__ import annotations

from typing import Any


def radio_readiness_errors(radio: Any, requested: str, configured: bool = True) -> list[str]:
    if not isinstance(radio, dict):
        return ["missing radio telemetry; extended Coded build required"]
    errors = []
    if radio.get("ready") is not True:
        errors.append(f"radio not ready: {radio.get('last_error')}")
    for key in ("primary_phy", "secondary_phy", "scan_phy"):
        if radio.get(key) != "coded":
            errors.append(f"{key} must be coded")
    if radio.get("advertising_interval_units") != 400:
        errors.append("radio advertising interval must be 250 ms / 400 units")
    if configured and radio.get("requested_mode") != requested:
        errors.append("requested radio mode mismatch")
    if requested == "coded_s8_required":
        if radio.get("coding_selection_support") != "supported":
            errors.append("controller cannot require S8")
        if configured and radio.get("s8_requirement_accepted") is not True:
            errors.append("controller has not accepted S8 requirement")
    return errors
