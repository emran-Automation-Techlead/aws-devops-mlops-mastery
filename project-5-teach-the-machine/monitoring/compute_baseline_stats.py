"""
Run ONCE after each successful training run to snapshot what "normal"
input data looks like - the reference distribution drift_detector.py
compares live traffic against. Without a baseline, "has the data
drifted?" is meaningless; you can only answer "drifted compared to
what?"

Usage:
    python compute_baseline_stats.py --features-path ../training/sample_features.parquet --out baseline_stats.json
    aws s3 cp baseline_stats.json s3://<bucket>/monitoring/baseline_stats.json
"""
import argparse
import json

import numpy as np
import pandas as pd

NUMERIC_FEATURES = [
    "amount_log",
    "hour_sin",
    "hour_cos",
    "txn_count_last_hour",
    "distance_from_home_km",
    "card_age_days",
]

N_BINS = 10


def compute_baseline(df: pd.DataFrame) -> dict:
    baseline = {}
    for col in NUMERIC_FEATURES:
        if col not in df.columns:
            continue
        # Quantile-based bin edges, not equal-width - equal-width bins on
        # a skewed feature like amount_log would put almost all the mass
        # in one or two bins, making PSI meaningless. Quantile bins start
        # with ~10% of the baseline data in each bin by construction.
        edges = np.quantile(df[col], np.linspace(0, 1, N_BINS + 1))
        edges[0] = -np.inf
        edges[-1] = np.inf
        baseline[col] = {"bin_edges": edges.tolist()}
    return baseline


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--features-path", required=True)
    parser.add_argument("--out", default="baseline_stats.json")
    args = parser.parse_args()

    df = pd.read_parquet(args.features_path) if args.features_path.endswith(".parquet") else pd.read_csv(args.features_path)
    baseline = compute_baseline(df)

    with open(args.out, "w") as f:
        json.dump(baseline, f, indent=2)
    print(f"Wrote baseline stats for {len(baseline)} features to {args.out}")
