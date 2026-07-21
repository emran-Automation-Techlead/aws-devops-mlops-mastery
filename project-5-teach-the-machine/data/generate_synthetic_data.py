"""
Generates a synthetic credit card transaction dataset with a fraud label.

Why synthetic data? Real fraud datasets are either private (banks don't
publish them) or come with licensing restrictions that don't belong in a
public teaching repo. This generates data with realistic STRUCTURE -
skewed transaction amounts, a rare positive class (~2% fraud, matching
real-world fraud rates), time-of-day patterns, geographic velocity - so
every downstream step (feature engineering, training, drift detection)
has something genuinely representative to work with. It is NOT a
substitute for real transaction data in production.

Usage:
    python generate_synthetic_data.py --rows 50000 --out transactions.csv
    aws s3 cp transactions.csv s3://<your-raw-data-bucket>/transactions/
"""
import argparse

import numpy as np
import pandas as pd

RNG = np.random.default_rng(42)


def generate(n_rows: int) -> pd.DataFrame:
    fraud_rate = 0.02
    is_fraud = RNG.random(n_rows) < fraud_rate

    # Fraudulent transactions skew toward larger amounts, odd hours, and
    # first-time merchants - not universally true in reality, but a
    # defensible simplification for a teaching dataset.
    amount = np.where(
        is_fraud,
        RNG.lognormal(mean=5.5, sigma=1.2, size=n_rows),
        RNG.lognormal(mean=3.5, sigma=1.0, size=n_rows),
    ).round(2)

    hour = np.where(
        is_fraud,
        RNG.choice(range(24), size=n_rows, p=_night_weighted_hours()),
        RNG.integers(0, 24, size=n_rows),
    )

    merchant_category = RNG.choice(
        ["grocery", "electronics", "travel", "gas", "restaurant", "online"],
        size=n_rows,
        p=[0.30, 0.10, 0.05, 0.20, 0.20, 0.15],
    )

    # A crude "velocity" proxy - transactions in the last hour for this
    # card. Fraud tends to cluster (card testing, rapid-fire purchases).
    txn_count_last_hour = np.where(
        is_fraud,
        RNG.poisson(4, size=n_rows),
        RNG.poisson(0.3, size=n_rows),
    )

    distance_from_home_km = np.where(
        is_fraud,
        RNG.exponential(scale=400, size=n_rows),
        RNG.exponential(scale=15, size=n_rows),
    ).round(1)

    card_age_days = RNG.integers(1, 3650, size=n_rows)

    df = pd.DataFrame(
        {
            "transaction_id": [f"txn_{i:08d}" for i in range(n_rows)],
            "amount": amount,
            "hour_of_day": hour,
            "merchant_category": merchant_category,
            "txn_count_last_hour": txn_count_last_hour,
            "distance_from_home_km": distance_from_home_km,
            "card_age_days": card_age_days,
            "is_fraud": is_fraud.astype(int),
        }
    )
    return df.sample(frac=1, random_state=42).reset_index(drop=True)


def _night_weighted_hours():
    # Weight late-night/early-morning hours higher for fraud.
    weights = np.ones(24)
    weights[0:6] = 3.0
    weights[22:24] = 2.5
    return weights / weights.sum()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=50_000)
    parser.add_argument("--out", type=str, default="transactions.csv")
    args = parser.parse_args()

    df = generate(args.rows)
    df.to_csv(args.out, index=False)
    print(f"Wrote {len(df)} rows to {args.out} ({df['is_fraud'].mean():.2%} fraud rate)")
