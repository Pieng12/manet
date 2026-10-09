"""Controller-only testbed definitions; the BLE transport remains unchanged."""
from dataclasses import dataclass

from .config import ConfigError

ESP_ONLY = "esp_only_five_v1"
RECOVERY_ESP = "esp_only_recovery_180_v1"
RECOVERY_ANDROID = "android_five_recovery_180_v1"
RECOVERY_VERSION = "same-node-recovery-v1"
ESP_SCENARIOS = {
    "S0_STABLE": {"observation_window_seconds": 180, "activate_at_seconds": None,
                  "inactive_node_ids": []},
    "S1_BRANCH_DELAYED": {"observation_window_seconds": 180, "activate_at_seconds": 60,
                          "inactive_node_ids": ["esp-r2b", "esp-destination"]},
    "S2_POST_DATA_STOP": {"observation_window_seconds": 420, "activate_at_seconds": 300,
                         "inactive_node_ids": ["esp-destination"]},
}
RECOVERY_SCENARIOS = {
    **ESP_SCENARIOS,
    "S2_POST_DATA_STOP": {"observation_window_seconds": 180, "activate_at_seconds": 90,
                         "inactive_node_ids": ["esp-destination"]},
}


def recovery_profile(document):
    return document.get("testbed_profile") in {RECOVERY_ESP, RECOVERY_ANDROID}


def scenario_design(document):
    return RECOVERY_SCENARIOS if recovery_profile(document) else ESP_SCENARIOS


def evidence_profile(document):
    return document.get("testbed_profile") == ESP_ONLY or recovery_profile(document)


@dataclass(frozen=True)
class Testbed:
    source: str
    targets: tuple[str, ...]
    edges: tuple[tuple[str, str], ...]
    esp_only: bool = False

    @property
    def node_ids(self):
        return (self.source, *self.targets)

    def adjacency(self, node):
        from .neighbor_experiment import stable_id
        return [stable_id(b if a == node else a) for a, b in self.edges if node in (a, b)]

    def metadata(self):
        return {"source_node_id": self.source, "target_node_ids": list(self.targets),
                "graph": [list(e) for e in self.edges]}


def testbed(document):
    esp = document.get("testbed_profile") in {ESP_ONLY, RECOVERY_ESP}
    source = "esp-r1b" if esp else "android-source"
    targets = (("esp-r1a", "esp-r2a", "esp-r2b", "esp-destination") if esp else
               ("esp-r1a", "esp-r1b", "esp-r2a", "esp-r2b", "esp-destination"))
    edges = ((source, "esp-r1a"), (source, "esp-r2a"), ("esp-r1a", "esp-r2a"),
             ("esp-r1a", "esp-r2b"), ("esp-r2b", "esp-destination")) if esp else (
             (source, "esp-r1a"), (source, "esp-r1b"), ("esp-r1a", "esp-r2a"),
             ("esp-r1b", "esp-r2a"), ("esp-r1a", "esp-r2b"),
             ("esp-r2b", "esp-destination"))
    value = Testbed(source, targets, edges, esp)
    if esp or recovery_profile(document):
        for key, expected in value.metadata().items():
            actual = document.get(key)
            if actual is not None and actual != expected:
                raise ConfigError(f"Testbed {key} mismatch")
    return value


def scenario_parameters(document, scenario):
    if evidence_profile(document):
        scenarios = scenario_design(document)
        if scenario not in scenarios:
            raise ConfigError(f"Unknown testbed scenario: {scenario}")
        return scenarios[scenario]
    return {"observation_window_seconds": document["observation_window_seconds"]}
