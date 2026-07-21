# Same multi-stage pattern as Project 3's services (see
# project-3-box-everything/services/*/Dockerfile for the full
# explanation) - here it matters even more, since scikit-learn/xgboost
# pull in compiled numeric libraries that bloat a single-stage image
# considerably more than Project 3's plain FastAPI services did.
FROM python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.11-slim

RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app

COPY --from=builder /root/.local /home/appuser/.local
COPY app.py .
RUN chown -R appuser:appuser /app

ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    MODEL_DIR=/opt/ml/model

# /opt/ml/model is SageMaker's own convention for where a mounted model
# artifact lives - matching it here means this exact image works
# unmodified whether it's deployed as a SageMaker Endpoint (SageMaker
# mounts model.tar.gz here automatically) or on EKS (the Helm chart
# mounts a volume at this same path - see helm/model-server/values.yaml).
RUN mkdir -p /opt/ml/model && chown -R appuser:appuser /opt/ml/model

USER appuser
EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
