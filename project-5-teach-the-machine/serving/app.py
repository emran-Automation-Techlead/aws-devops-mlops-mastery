"""
Model server with a DUAL contract, on purpose:

  - /ping and /invocations - the exact endpoints the SageMaker hosting
    contract requires. Any container implementing these two can be
    deployed as a real-time SageMaker Endpoint, used for shadow testing
    or as a fallback path, without changing a line of code.
  - /health and /metrics - what actually gets used day-to-day, since
    this project deploys the SAME image to EKS (helm/model-server) rather
    than a SageMaker Endpoint. /health matches the readiness/liveness
    probe pattern from Project 4; /metrics exposes Prometheus-format
    request rate/latency, feeding the same Grafana stack Project 4 set
    up, now extended with prediction-specific panels
    (monitoring/grafana-dashboard.json).

One container, two deployment targets - which one you actually use
depends on where you point traffic, not on rebuilding the image.
"""
import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

import boto3
import joblib
import pandas as pd
from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_fastapi_instrumentator import Instrumentator
from prometheus_client import Counter, Histogram
from pydantic import BaseModel

MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/opt/ml/model"))
PREDICTION_LOG_TABLE = os.environ.get("PREDICTION_LOG_TABLE")
_dynamodb_table = boto3.resource("dynamodb").Table(PREDICTION_LOG_TABLE) if PREDICTION_LOG_TABLE else None


def _log_prediction(features: dict, score: float):
    """Feeds monitoring/drift_detector.py - every prediction's input
    features + score get a row here, which is what drift detection reads
    to compare "what the model is seeing now" against the training-time
    baseline. Best-effort: a logging failure should never break a
    prediction response, so exceptions are swallowed, not raised."""
    if _dynamodb_table is None:
        return
    try:
        now = datetime.now(timezone.utc)
        item = {
            "prediction_id": str(uuid.uuid4()),
            "timestamp": now.isoformat(),
            # DynamoDB TTL (terraform/dynamodb.tf) auto-deletes rows past
            # this epoch-seconds value - 30 days is comfortably longer
            # than drift_detector.py's lookback window.
            "expires_at": int(now.timestamp()) + 30 * 24 * 3600,
            "fraud_probability": str(round(score, 6)),
        }
        item.update({k: str(v) for k, v in features.items()})
        _dynamodb_table.put_item(Item=item)
    except Exception as e:
        print(f"WARNING: failed to log prediction for drift monitoring: {e}")

app = FastAPI(title="Fraud Detection Model Server")
Instrumentator().instrument(app).expose(app)

# Custom metrics, beyond what the instrumentator gives us for free -
# these are what the drift/accuracy panels in the Grafana dashboard read.
# A model that starts predicting very differently from its training
# distribution is often the earliest signal of drift - visible here
# before accuracy metrics would even catch it.
PREDICTION_SCORE = Histogram(
    "model_prediction_score",
    "Distribution of predicted fraud probabilities",
    buckets=[0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0],
)
FRAUD_FLAGGED_TOTAL = Counter(
    "model_fraud_flagged_total", "Count of predictions that crossed the fraud threshold"
)

_model = None
_scaler = None
_feature_columns = None


def _load_model():
    global _model, _scaler, _feature_columns
    if _model is None:
        _model = joblib.load(MODEL_DIR / "model.joblib")
        _scaler = joblib.load(MODEL_DIR / "scaler.joblib")
        with open(MODEL_DIR / "feature_columns.json") as f:
            _feature_columns = json.load(f)
    return _model, _scaler, _feature_columns


class Transaction(BaseModel):
    amount_log: float
    hour_sin: float
    hour_cos: float
    is_night: int
    txn_count_last_hour: int
    high_velocity: int
    distance_from_home_km: float
    far_from_home: int
    card_age_days: int
    new_card: int
    merchant_electronics: int = 0
    merchant_gas: int = 0
    merchant_grocery: int = 0
    merchant_online: int = 0
    merchant_restaurant: int = 0
    merchant_travel: int = 0


# ---- SageMaker hosting contract ----


@app.get("/ping")
def ping():
    """SageMaker calls this to decide if the container is healthy enough
    to receive traffic. Must return 200 fast - loading the model here
    (rather than at request time) is what makes that possible."""
    try:
        _load_model()
        return Response(status_code=200)
    except Exception:
        return Response(status_code=503)


@app.post("/invocations")
async def invocations(request: Request):
    """SageMaker's real-time endpoint contract: raw bytes in, raw bytes
    out, content-type negotiated via headers - deliberately more raw than
    a typical REST API, since SageMaker itself handles the HTTP framing
    around this."""
    model, scaler, feature_columns = _load_model()
    body = await request.body()
    payload = json.loads(body)

    # reindex, not a plain column selection: a caller sending a
    # transaction from a merchant category not seen at train time (or
    # simply omitting a one-hot column that's 0 for them) should get a
    # 0-filled column, not a KeyError. Same tolerance /predict already
    # gets for free from Pydantic's field defaults.
    df = pd.DataFrame([payload]).reindex(columns=feature_columns, fill_value=0)
    X_scaled = scaler.transform(df)
    score = float(model.predict_proba(X_scaled)[0, 1])

    PREDICTION_SCORE.observe(score)
    if score >= 0.5:
        FRAUD_FLAGGED_TOTAL.inc()
    _log_prediction(dict(zip(feature_columns, df.iloc[0])), score)

    return Response(
        content=json.dumps({"fraud_probability": score, "is_fraud": score >= 0.5}),
        media_type="application/json",
    )


# ---- Kubernetes / everyday contract ----


@app.get("/health")
def health():
    try:
        _load_model()
        return {"status": "ok"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@app.post("/predict")
def predict(txn: Transaction):
    """Same logic as /invocations, but a normal typed JSON API - what the
    order-service-style callers on EKS actually use day-to-day. /invocations
    stays SageMaker-contract-literal; this is the ergonomic version."""
    model, scaler, feature_columns = _load_model()
    row = {c: getattr(txn, c, 0) for c in feature_columns if c != "transaction_id"}
    df = pd.DataFrame([row])
    X_scaled = scaler.transform(df)
    score = float(model.predict_proba(X_scaled)[0, 1])

    PREDICTION_SCORE.observe(score)
    if score >= 0.5:
        FRAUD_FLAGGED_TOTAL.inc()
    _log_prediction(row, score)

    return {"fraud_probability": score, "is_fraud": score >= 0.5}
