"""Generate SYNTHETIC data in a new directory. Never contacts hardware."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent/"experiment_controller"))
from resqmesh_controller.neighbor_experiment import METHODS, SOURCE, TARGETS, adjacency, merge_neighbor, stable_id, summarize_network


def generate(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    raw = output/"raw"
    raw.mkdir()
    manifest = {"session_id": "SYNTHETIC-NOT-HARDWARE", "synthetic_data": True,
                "data_origin": "Fixture perangkat lunak; bukan hasil pilot/perangkat fisik",
                "neighbor_scenarios": ["S0_MAIN", "S1_DELAYED_RX", "S2_LATE_JOIN"],
                "radio_readiness": {SOURCE: {"requested_mode": "coded", "configured_mode": "coded", "ready": True,
                                            "coding_selection_support": "unsupported", "on_air_coding_verified": False}}, "trials": {}}
    events = []
    for method_index, method in enumerate(METHODS):
        for index in range(method_index+1):
            trial = f"synthetic-{method_index}-{index}"
            scope, t0 = stable_id(trial), 10000 + len(manifest["trials"])*100000
            message = f"123:{t0-1000}"
            def event(kind, node, at, seq=1, tx=None):
                return {"event_type": kind, "node_id": node, "session_id": manifest["session_id"], "trial_id": trial,
                        "message_key": message, "scope": scope, "transmitter_id": stable_id(node) if tx is None else tx,
                        "boot_id": 1, "transmission_sequence": seq, "timestamp_ms": at, "clock_sync_valid": True,
                        "clock_offset_ms": 0, "synthetic_data": True}
            received_nodes = TARGETS if index == 0 else TARGETS[:2] if index == 1 else ()
            trial_events = [event("SOS_CREATED", SOURCE, t0-1000), event("SOURCE_FIRST_ADVERTISE_STARTED", SOURCE, t0),
                            event("DATA_BURST_STARTED", SOURCE, t0)]
            if method == METHODS[3]:
                trial_events += [event("STATUS_BURST_STARTED", TARGETS[0], t0-500, 20),
                                 event("STATUS_BURST_STARTED", TARGETS[0], t0+1000, 21)]
            trial_events += [event("DATA_RECEIVED", node, t0+100*(i+1), tx=adjacency(node)[0]) for i, node in enumerate(received_nodes)]
            if received_nodes:
                trial_events.append(dict(trial_events[-1]))
            result = "SUCCESS" if len(received_nodes) == 5 else "FAILED_DELIVERY"
            if index == 3:
                result = "INVALID"
            record = {"device_trial_id": trial, "trial_id": trial, "session_id": manifest["session_id"],
                      "mode": method, "hypothesis": "S0_MAIN", "result": result, "block": index+1,
                      "observation_started_at_ms": t0, "observation_ended_at_ms": t0+60000, "scope": scope,
                      "invalid_reasons": ["SYNTHETIC_INVALID_EXAMPLE"] if result == "INVALID" else []}
            record["evidence"] = summarize_network(trial_events, record)
            manifest["trials"][trial] = record
            events.extend(trial_events)
    (raw/"SYNTHETIC-events.jsonl").write_text("\n".join(json.dumps(e) for e in events), encoding="utf-8")
    (output/"manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return merge_neighbor(raw, output/"merged", manifest)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    print(json.dumps(generate(parser.parse_args().output), indent=2))
