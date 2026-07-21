"""
Lambda function, run on a schedule (see terraform/lambda.tf - every 6
hours by default). Compares recent live prediction traffic against the
training-time baseline (compute_baseline_stats.py) using Population
Stability Index (PSI) - a standard, widely-used metric for exactly this
question: "has the distribution of an input feature shifted enough to
worry about?"

PSI, in plain terms: split the baseline data into bins. Count what % of
RECENT data falls in each of those same bins. PSI compares the two
percentage distributions - if recent traffic clusters in bins the
baseline rarely used, PSI goes up. Rule-of-thumb thresholds (from
standard industry practice, not something invented for this project):
  PSI < 0.1  -> no significant shift
  0.1 - 0.25 -> moderate shift, worth watching
  PSI > 0.25 -> significant shift, investigate/retrain

Why this instead of just watching accuracy drop? Accuracy needs ground-
truth labels, which for fraud might not exist for days or weeks (you
often don't know a transaction was fraud until a chargeback happens).
Feature drift is measurable IMMEDIATELY, using only the inputs you
already have - the earliest possible warning signal.
"""
import json
import os
from datetime import datetime, timedelta, timezone

import boto3
import numpy as np

PSI_THRESHOLD = float(os.environ.get("PSI_THRESHOLD", "0.25"))
BASELINE_BUCKET = os.environ["BASELINE_BUCKET"]
BASELINE_KEY = os.environ.get("BASELINE_KEY", "monitoring/baseline_stats.json")
PREDICTION_LOG_TABLE = os.environ["PREDICTION_LOG_TABLE"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
STATE_MACHINE_ARN = os.environ.get("STATE_MACHINE_ARN", "")
RAW_DATA_S3_URI = os.environ.get("RAW_DATA_S3_URI", "")
LOOKBACK_HOURS = int(os.environ.get("LOOKBACK_HOURS", "6"))

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
cloudwatch = boto3.client("cloudwatch")
sns = boto3.client("sns")
sfn = boto3.client("stepfunctions")


def compute_psi(baseline_edges: list[float], recent_values: list[float]) -> float:
    n_bins = len(baseline_edges) - 1
    # Baseline is uniform by construction (compute_baseline_stats.py uses
    # quantile bins, so ~1/n_bins of the baseline falls in each bin).
    baseline_pct = np.full(n_bins, 1.0 / n_bins)

    recent_counts, _ = np.histogram(recent_values, bins=baseline_edges)
    recent_pct = recent_counts / max(len(recent_values), 1)

    # Floor both distributions away from exactly 0 - PSI's log term is
    # undefined at 0, and a bin genuinely having zero recent traffic is
    # itself meaningful signal, not something to silently drop.
    baseline_pct = np.clip(baseline_pct, 1e-4, None)
    recent_pct = np.clip(recent_pct, 1e-4, None)

    return float(np.sum((recent_pct - baseline_pct) * np.log(recent_pct / baseline_pct)))


def fetch_recent_predictions(table_name: str, lookback_hours: int) -> list[dict]:
    table = dynamodb.Table(table_name)
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=lookback_hours)).isoformat()

    # A full table scan with a filter is the simplest correct approach
    # for a teaching-scale table. At real production volume, this table
    # would have a GSI on a coarse time-bucket partition key so this
    # becomes a Query, not a Scan - called out here rather than glossed
    # over, since it's the real limit of this implementation.
    items = []
    scan_kwargs = {"FilterExpression": boto3.dynamodb.conditions.Attr("timestamp").gte(cutoff)}
    while True:
        response = table.scan(**scan_kwargs)
        items.extend(response["Items"])
        if "LastEvaluatedKey" not in response:
            break
        scan_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
    return items


def handler(event, context):
    baseline_obj = s3.get_object(Bucket=BASELINE_BUCKET, Key=BASELINE_KEY)
    baseline = json.loads(baseline_obj["Body"].read())

    recent = fetch_recent_predictions(PREDICTION_LOG_TABLE, LOOKBACK_HOURS)
    if len(recent) < 30:
        print(f"Only {len(recent)} predictions in the last {LOOKBACK_HOURS}h - too few to measure drift reliably, skipping.")
        return {"status": "skipped", "reason": "insufficient_data", "sample_size": len(recent)}

    psi_scores = {}
    for feature, stats in baseline.items():
        values = [float(item[feature]) for item in recent if feature in item]
        if not values:
            continue
        psi_scores[feature] = compute_psi(stats["bin_edges"], values)

    # One CloudWatch metric per feature - this is exactly what the
    # Grafana dashboard's "Drift Score" panel queries (via the CloudWatch
    # datasource), and what lets you see WHICH feature drifted, not just
    # a single opaque "drift: yes/no."
    for feature, psi in psi_scores.items():
        cloudwatch.put_metric_data(
            Namespace="MLOps/DriftDetection",
            MetricData=[
                {
                    "MetricName": "PSI",
                    "Dimensions": [{"Name": "Feature", "Value": feature}],
                    "Value": psi,
                    "Unit": "None",
                }
            ],
        )

    max_feature, max_psi = max(psi_scores.items(), key=lambda kv: kv[1])
    drifted = max_psi > PSI_THRESHOLD

    result = {
        "status": "drift_detected" if drifted else "ok",
        "sample_size": len(recent),
        "psi_scores": psi_scores,
        "max_drift_feature": max_feature,
        "max_psi": max_psi,
        "threshold": PSI_THRESHOLD,
    }
    print(json.dumps(result, indent=2))

    if drifted:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"Drift detected: {max_feature} (PSI={max_psi:.3f})",
            Message=(
                f"Feature '{max_feature}' has drifted from its training-time baseline "
                f"(PSI={max_psi:.3f}, threshold={PSI_THRESHOLD}). "
                f"Based on {len(recent)} predictions in the last {LOOKBACK_HOURS}h.\n\n"
                f"Full PSI scores: {json.dumps(psi_scores, indent=2)}\n\n"
                + ("Triggering automated retraining." if STATE_MACHINE_ARN else "No retraining state machine configured - manual action needed.")
            ),
        )

        if STATE_MACHINE_ARN:
            sfn.start_execution(
                stateMachineArn=STATE_MACHINE_ARN,
                input=json.dumps(
                    {
                        "trigger_reason": f"drift:{max_feature}:psi={max_psi:.3f}",
                        "raw_data_s3_uri": RAW_DATA_S3_URI,
                    }
                ),
            )

    return result
