from __future__ import annotations

from typing import Any

COMPARISONS = (
    ("overall_mechanism", "basic_flooding", "trickle"),
    ("suppression_contribution", "trickle_no_suppression", "trickle"),
)


def descriptive_comparisons(aggregates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Observed differences only; no p-values or equivalence claims."""
    indexed = {(r["mode"], r["hypothesis"]): r for r in aggregates}
    rows = []
    for name, baseline, treatment in COMPARISONS:
        for hop in ("H1", "H2", "H3"):
            left, right = indexed.get((baseline, hop)), indexed.get((treatment, hop))
            if left is None or right is None:
                continue
            for metric in ("dsr", "e2e_median", "ldr", "ldr_mean_per_trial", "transmission_overhead"):
                a, b = left.get(metric), right.get(metric)
                rows.append({"comparison": name, "hypothesis": hop, "metric": metric,
                             "baseline": baseline, "treatment": treatment,
                             "baseline_valid_trials": left["valid_trials"],
                             "treatment_valid_trials": right["valid_trials"],
                             "baseline_value": a, "treatment_value": b,
                             "difference_treatment_minus_baseline": b - a if a is not None and b is not None else None,
                             "analysis": "Deskriptif; unit analisis adalah trial; bukan klaim inferensi atau equivalence"})
    return rows
