#!/usr/bin/env bash
#
# Builds all 3 service images, tags each with three tags, pushes to ECR,
# and forces an ECS rolling deployment so the running services pick up
# the new image.
#
# Why three tags per image, not just one?
#   latest        - "give me whatever's newest" (convenient, not safe to
#                    pin a production deployment to, since it silently
#                    changes meaning)
#   v1.0.0         - a human-chosen release version (from VERSION file) -
#                    stable, meaningful, but only changes when you decide to
#   <git-sha>      - the exact, immutable commit this image was built
#                    from - what you'd actually reference to answer
#                    "what code is running in prod right now?"
#
# Usage: ./deploy-ecs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"

SERVICES=("user-service" "product-service" "order-service")
VERSION="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo "v0.0.0")"
GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

echo "==> Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not configured or are invalid."
  exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region 2>/dev/null || echo "us-east-1")
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw ecs_cluster_name)

echo "==> Logging in to ECR ($ECR_REGISTRY)..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

for SERVICE in "${SERVICES[@]}"; do
  REPO_NAME="box-everything-${SERVICE}"
  IMAGE_BASE="${ECR_REGISTRY}/${REPO_NAME}"

  echo ""
  echo "==> Building ${SERVICE}..."
  docker build -t "${IMAGE_BASE}:latest" "$PROJECT_DIR/services/${SERVICE}"

  docker tag "${IMAGE_BASE}:latest" "${IMAGE_BASE}:${VERSION}"
  docker tag "${IMAGE_BASE}:latest" "${IMAGE_BASE}:${GIT_SHA}"

  echo "==> Pushing ${SERVICE} (latest, ${VERSION}, ${GIT_SHA})..."
  docker push "${IMAGE_BASE}:latest"
  docker push "${IMAGE_BASE}:${VERSION}"
  docker push "${IMAGE_BASE}:${GIT_SHA}"

  echo "==> Forcing ECS rolling deployment for ${SERVICE}..."
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "box-everything-${SERVICE}" \
    --force-new-deployment \
    --query "service.serviceName" --output text
done

echo ""
echo "==> All 3 services deployed. ECS is now rolling out the new tasks -"
echo "    old tasks keep serving traffic until new ones pass health checks."
echo "    Watch progress: aws ecs describe-services --cluster $CLUSTER_NAME --services box-everything-user-service"
