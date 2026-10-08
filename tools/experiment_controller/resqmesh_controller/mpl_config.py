"""Versioned BLE/MPL research profile. Historical neighbor profiles are unchanged."""
from .config import ConfigError

SEMANTICS = "resqmesh-trickle-mpl-v1"
METHODS = ("basic_flooding", "trickle", "trickle_mpl")
DEFAULTS = {
    "mpl_data_imin_ms": 8000, "mpl_data_imax_ms": 256000,
    "mpl_data_k": 1, "mpl_data_expirations": 5,
    "mpl_control_imin_ms": 4000, "mpl_control_imax_ms": 32000,
    "mpl_control_k": 1, "mpl_control_expirations": 4,
    "mpl_repair_cooldown_ms": 8000, "mpl_repair_budget": 2,
    "mpl_repair_expiry_ms": 60000, "mpl_bootstrap_opportunities": 2,
    "mpl_retry_ms": 1000, "mpl_retry_limit": 3,
    "mpl_probe_interval_ms": 60000, "mpl_probe_limit": 0,
    "mpl_freshness_ms": 150000, "mpl_discovery_jitter_ms": 1500,
}


def enabled(config):
    return config.get("scheduler_semantics") == SEMANTICS


def methods(config):
    if enabled(config):
        return METHODS
    from .neighbor_experiment import METHODS as historical
    return historical


def parameters(config):
    overrides = config.get("mpl_parameters", {})
    if not isinstance(overrides, dict) or set(overrides) - set(DEFAULTS):
        raise ConfigError("unknown MPL parameter")
    p = {**DEFAULTS, **overrides}
    if any(type(v) is not int or not 0 <= v <= 0x1fffffff for v in p.values()):
        raise ConfigError("invalid MPL timer integer")
    for kind in ("data", "control"):
        a, b = (p[f"mpl_{kind}_{s}_ms"] for s in ("imin", "imax"))
        if a < 2000 or b < a or b % a or (b//a) & (b//a-1) or p[f"mpl_{kind}_k"] < 1 or not 1 <= p[f"mpl_{kind}_expirations"] <= 32:
            raise ConfigError("unsafe MPL Trickle timer")
    if (p["mpl_repair_cooldown_ms"] < p["mpl_data_imin_ms"] or
            p["mpl_repair_expiry_ms"] < p["mpl_repair_cooldown_ms"] or
            not 1 <= p["mpl_repair_budget"] <= 8 or p["mpl_bootstrap_opportunities"] > 8 or
            not 1 <= p["mpl_retry_limit"] <= 8 or p["mpl_retry_ms"] < 250 or
            p["mpl_freshness_ms"] < p["mpl_control_imin_ms"] or p["mpl_probe_limit"] > 8 or
            p["mpl_probe_interval_ms"] < p["mpl_control_imax_ms"]):
        raise ConfigError("unsafe MPL repair/discovery bounds")
    return p
