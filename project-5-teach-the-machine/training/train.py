"""
Trains ONE model (LogisticRegression, XGBoost, or an MLP as the "neural
net") and logs the run to MLflow. Written as a SageMaker script-mode
entrypoint - reads hyperparameters via argparse (SageMaker injects these
as CLI args) and data/output paths via the SM_CHANNEL_*/SM_MODEL_DIR
environment variables SageMaker sets automatically, falling back to
sensible local defaults so this same script runs unmodified on a laptop.

The SageMaker Pipeline (pipelines/sagemaker_pipeline.py) runs this
script 3 times in parallel, once per --model-type - "training 3 models"
means 3 separate Training Jobs, not one script with an internal loop,
because that's what actually lets them run concurrently and shows up as
3 distinct, comparable runs in MLflow and 3 distinct entries in the
SageMaker console.

Usage (local):
    python train.py --model-type logistic_regression \\
        --train-path ../features/sample_features.parquet \\
        --mlflow-tracking-uri file:./mlruns
"""
import argparse
import json
import os
from pathlib import Path

import joblib
import mlflow
import pandas as pd
from sklearn.ensemble import RandomForestClassifier  # noqa: F401 (kept available for quick experimentation)
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler
from xgboost import XGBClassifier

MODEL_BUILDERS = {
    "logistic_regression": lambda: LogisticRegression(max_iter=1000, class_weight="balanced"),
    "xgboost": lambda: XGBClassifier(
        n_estimators=200,
        max_depth=5,
        learning_rate=0.1,
        # Fraud is ~2% positive class - scale_pos_weight tells XGBoost to
        # weight the rare class higher, instead of learning "always
        # predict not-fraud" and getting 98% accuracy while catching
        # zero fraud.
        scale_pos_weight=45,
        eval_metric="logloss",
    ),
    "neural_net": lambda: MLPClassifier(
        hidden_layer_sizes=(64, 32),
        max_iter=300,
        early_stopping=True,
    ),
}


def load_features(path: str) -> pd.DataFrame:
    if path.endswith(".parquet"):
        return pd.read_parquet(path)
    return pd.read_csv(path)


def train(model_type: str, train_path: str, model_dir: str, mlflow_tracking_uri: str, experiment_name: str):
    mlflow.set_tracking_uri(mlflow_tracking_uri)
    mlflow.set_experiment(experiment_name)

    df = load_features(train_path)
    y = df["is_fraud"]
    X = df.drop(columns=["is_fraud", "transaction_id"])

    X_train, X_val, y_train, y_val = train_test_split(
        X, y, test_size=0.2, stratify=y, random_state=42
    )

    # Neural nets and logistic regression are sensitive to feature
    # scale (a $10,000 amount vs. a 0/1 flag dominates gradient updates
    # otherwise); tree-based XGBoost doesn't need this, but scaling it
    # anyway costs nothing and keeps the pipeline uniform across model
    # types.
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_val_scaled = scaler.transform(X_val)

    with mlflow.start_run(run_name=model_type):
        mlflow.log_param("model_type", model_type)
        mlflow.log_param("train_rows", len(X_train))
        mlflow.log_param("val_rows", len(X_val))
        mlflow.log_param("n_features", X.shape[1])

        model = MODEL_BUILDERS[model_type]()
        model.fit(X_train_scaled, y_train)

        val_probs = model.predict_proba(X_val_scaled)[:, 1]
        val_preds = (val_probs >= 0.5).astype(int)

        from sklearn.metrics import (
            accuracy_score,
            f1_score,
            precision_score,
            recall_score,
            roc_auc_score,
        )

        metrics = {
            "accuracy": accuracy_score(y_val, val_preds),
            "precision": precision_score(y_val, val_preds, zero_division=0),
            "recall": recall_score(y_val, val_preds, zero_division=0),
            "f1": f1_score(y_val, val_preds, zero_division=0),
            "roc_auc": roc_auc_score(y_val, val_probs),
        }
        mlflow.log_metrics(metrics)
        mlflow.sklearn.log_model(model, artifact_path="model")

        print(f"[{model_type}] validation metrics: {json.dumps(metrics, indent=2)}")

        # SageMaker packages everything under SM_MODEL_DIR into
        # model.tar.gz automatically after the training job exits - this
        # is what evaluation.py and the Model Registry step consume.
        Path(model_dir).mkdir(parents=True, exist_ok=True)
        joblib.dump(model, Path(model_dir) / "model.joblib")
        joblib.dump(scaler, Path(model_dir) / "scaler.joblib")
        with open(Path(model_dir) / "metrics.json", "w") as f:
            json.dump(metrics, f, indent=2)
        with open(Path(model_dir) / "feature_columns.json", "w") as f:
            json.dump(list(X.columns), f)

        run_id = mlflow.active_run().info.run_id
        print(f"MLflow run_id: {run_id}")
        return run_id, metrics


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-type", choices=list(MODEL_BUILDERS.keys()), required=True)
    parser.add_argument("--train-path", type=str, default=os.environ.get("SM_CHANNEL_TRAIN", "train.parquet"))
    parser.add_argument("--model-dir", type=str, default=os.environ.get("SM_MODEL_DIR", "./model"))
    parser.add_argument(
        "--mlflow-tracking-uri",
        type=str,
        default=os.environ.get("MLFLOW_TRACKING_URI", "file:./mlruns"),
    )
    parser.add_argument("--experiment-name", type=str, default="fraud-detection")
    args = parser.parse_args()

    train_path = args.train_path
    if os.path.isdir(train_path):
        # SageMaker mounts the whole S3 "train" channel as a directory -
        # find the actual data file inside it.
        candidates = [f for f in os.listdir(train_path) if f.endswith((".parquet", ".csv"))]
        train_path = os.path.join(train_path, candidates[0])

    train(args.model_type, train_path, args.model_dir, args.mlflow_tracking_uri, args.experiment_name)
