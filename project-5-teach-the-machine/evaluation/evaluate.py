"""
Compares the 3 models train.py produced (one MLflow run each), picks the
winner, and registers ONLY the winner in SageMaker Model Registry. This
is the "Model Selection" step in the SageMaker Pipeline - it runs after
all 3 TrainingSteps complete, as a ProcessingStep.

Why ROC-AUC as the selection metric, not accuracy? With ~2% fraud in the
data, a model that predicts "not fraud" for every single transaction
scores 98% accuracy while catching zero fraud - accuracy is actively
misleading on imbalanced data like this. ROC-AUC measures how well the
model RANKS fraudulent transactions above legitimate ones across every
possible decision threshold, which is what actually matters for a fraud
system (you tune the threshold separately based on the false-positive
rate the business can tolerate).

Plain-language metric definitions (for the README, kept close to the
code that computes them):
  - Accuracy:  % of all predictions that were correct. Misleading here -
               see above.
  - Precision: of the transactions we FLAGGED as fraud, what % actually
               were? Low precision = annoying customers with false
               declines.
  - Recall:    of the transactions that WERE fraud, what % did we catch?
               Low recall = fraud slips through.
  - F1:        harmonic mean of precision and recall - one number when
               you need to balance both.
  - ROC-AUC:   probability the model ranks a random fraud case higher
               than a random legitimate one. 0.5 = coin flip, 1.0 =
               perfect ranking. Threshold-independent, which is why it's
               the primary selection metric here.
"""
import argparse
import json
import os
from pathlib import Path

import boto3
import mlflow


def load_run_metrics(mlflow_tracking_uri: str, experiment_name: str) -> list[dict]:
    mlflow.set_tracking_uri(mlflow_tracking_uri)
    client = mlflow.tracking.MlflowClient()
    experiment = client.get_experiment_by_name(experiment_name)
    if experiment is None:
        raise ValueError(f"No MLflow experiment named '{experiment_name}' found")

    runs = client.search_runs(
        experiment_ids=[experiment.experiment_id],
        order_by=["start_time DESC"],
        max_results=20,
    )

    # Only the most recent run per model_type - re-running training
    # shouldn't let a stale run from last week win the comparison.
    latest_by_type = {}
    for run in runs:
        model_type = run.data.params.get("model_type")
        if model_type and model_type not in latest_by_type:
            latest_by_type[model_type] = run

    return [
        {
            "model_type": model_type,
            "run_id": run.info.run_id,
            "metrics": run.data.metrics,
        }
        for model_type, run in latest_by_type.items()
    ]


def select_best(candidates: list[dict], metric: str = "roc_auc") -> dict:
    return max(candidates, key=lambda c: c["metrics"].get(metric, 0.0))


def get_current_registered_metric(model_package_group_name: str, region: str, metric: str) -> float:
    """The bar the new model has to clear: the currently-approved model's
    metric, if one exists. Returns 0.0 (anything beats it) if this is the
    first ever model for this group - a cold start shouldn't block the
    first registration."""
    sm = boto3.client("sagemaker", region_name=region)
    try:
        packages = sm.list_model_packages(
            ModelPackageGroupName=model_package_group_name,
            ModelApprovalStatus="Approved",
            SortBy="CreationTime",
            SortOrder="Descending",
            MaxResults=1,
        )["ModelPackageSummaryList"]
    except sm.exceptions.ClientError:
        return 0.0

    if not packages:
        return 0.0

    details = sm.describe_model_package(ModelPackageName=packages[0]["ModelPackageArn"])
    metrics_json = details.get("ModelMetrics", {}).get("ModelQuality", {}).get("Statistics", {})
    # Custom metrics are stored as an S3-hosted JSON blob referenced here
    # in a real pipeline; simplified to a direct field for this project's
    # scope. See register_model() below for how it's written.
    return metrics_json.get(metric, 0.0)


def register_model(
    candidate: dict,
    model_artifact_s3_path: str,
    image_uri: str,
    model_package_group_name: str,
    region: str,
) -> str:
    sm = boto3.client("sagemaker", region_name=region)
    response = sm.create_model_package(
        ModelPackageGroupName=model_package_group_name,
        ModelPackageDescription=f"{candidate['model_type']} - MLflow run {candidate['run_id']}",
        InferenceSpecification={
            "Containers": [{"Image": image_uri, "ModelDataUrl": model_artifact_s3_path}],
            "SupportedContentTypes": ["application/json"],
            "SupportedResponseMIMETypes": ["application/json"],
        },
        ModelApprovalStatus="PendingManualApproval",
        CustomerMetadataProperties={
            "model_type": candidate["model_type"],
            "mlflow_run_id": candidate["run_id"],
            "roc_auc": str(candidate["metrics"]["roc_auc"]),
            "f1": str(candidate["metrics"]["f1"]),
        },
    )
    return response["ModelPackageArn"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--mlflow-tracking-uri", default=os.environ.get("MLFLOW_TRACKING_URI", "file:./mlruns"))
    parser.add_argument("--experiment-name", default="fraud-detection")
    parser.add_argument("--model-package-group-name", default="fraud-detection-models")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--model-artifact-s3-path", required=False)
    parser.add_argument("--image-uri", required=False)
    parser.add_argument("--output-path", default="./evaluation_report.json")
    args = parser.parse_args()

    candidates = load_run_metrics(args.mlflow_tracking_uri, args.experiment_name)
    if not candidates:
        raise SystemExit("No training runs found - run train.py for all 3 model types first")

    best = select_best(candidates)
    current_best_metric = get_current_registered_metric(
        args.model_package_group_name, args.region, "roc_auc"
    )

    report = {
        "candidates": candidates,
        "selected": best,
        "current_registered_roc_auc": current_best_metric,
        "improved": best["metrics"]["roc_auc"] > current_best_metric,
    }

    with open(args.output_path, "w") as f:
        json.dump(report, f, indent=2)

    print(json.dumps(report, indent=2))

    # Every evaluation run - whether or not it results in a new registered
    # model - is a data point in "model accuracy over time," the panel in
    # monitoring/grafana-dashboard.json. Without this, that panel would
    # have nothing to plot; accuracy isn't something Prometheus scrapes
    # from a running service the way request latency is.
    cloudwatch = boto3.client("cloudwatch", region_name=args.region)
    cloudwatch.put_metric_data(
        Namespace="MLOps/ModelQuality",
        MetricData=[
            {
                "MetricName": metric_name,
                "Dimensions": [{"Name": "ModelType", "Value": best["model_type"]}],
                "Value": value,
                "Unit": "None",
            }
            for metric_name, value in best["metrics"].items()
        ],
    )

    if report["improved"] and args.model_artifact_s3_path and args.image_uri:
        arn = register_model(
            best,
            args.model_artifact_s3_path,
            args.image_uri,
            args.model_package_group_name,
            args.region,
        )
        print(f"Registered new best model: {arn}")
    elif not report["improved"]:
        print(
            f"Best candidate ({best['model_type']}, ROC-AUC={best['metrics']['roc_auc']:.4f}) "
            f"did not beat the currently registered model (ROC-AUC={current_best_metric:.4f}) - "
            "nothing registered. This is the 'deploy only if better' gate."
        )
