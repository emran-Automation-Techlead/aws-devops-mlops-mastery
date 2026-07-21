#!/bin/bash
# ValidateService hook - the pipeline's final safety check. If /health
# doesn't respond within the retry window, this script exits non-zero,
# CodeDeploy marks the deployment FAILED, and (with auto-rollback enabled)
# traffic never shifts to the broken version.
set -euo pipefail

echo "==> Validating the service responds on /health"
for i in $(seq 1 10); do
  if curl -sf http://localhost:3000/health > /dev/null; then
    echo "Service is healthy"
    exit 0
  fi
  echo "Attempt $i/10: not ready yet, retrying in 3s..."
  sleep 3
done

echo "ERROR: service did not become healthy in time"
exit 1
