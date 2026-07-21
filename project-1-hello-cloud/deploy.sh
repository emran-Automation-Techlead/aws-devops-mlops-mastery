#!/usr/bin/env bash
#
# Deploys index.html + styles.css to the S3 bucket provisioned by
# terraform/main.tf, then invalidates the CloudFront cache so visitors
# see the new version immediately instead of a stale cached copy.
#
# Usage: ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"

echo "==> Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not configured or are invalid."
  echo "Run 'aws configure' (or set up SSO) before deploying."
  exit 1
fi

echo "==> Reading infrastructure details from Terraform state..."
if ! BUCKET_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw bucket_name 2>/dev/null); then
  echo "ERROR: Could not read Terraform outputs."
  echo "Run 'terraform apply' in $TERRAFORM_DIR first."
  exit 1
fi
DISTRIBUTION_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw cloudfront_distribution_id)
SITE_URL=$(terraform -chdir="$TERRAFORM_DIR" output -raw site_url)

echo "==> Target bucket: $BUCKET_NAME"
echo "==> Target distribution: $DISTRIBUTION_ID"

echo "==> Uploading site files..."
aws s3 cp "$SCRIPT_DIR/index.html" "s3://$BUCKET_NAME/index.html" \
  --content-type "text/html" --cache-control "max-age=300"
aws s3 cp "$SCRIPT_DIR/styles.css" "s3://$BUCKET_NAME/styles.css" \
  --content-type "text/css" --cache-control "max-age=86400"

echo "==> Invalidating CloudFront cache..."
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --query "Invalidation.Id" \
  --output text)

echo "==> Invalidation submitted: $INVALIDATION_ID"
echo "    (takes ~30-60 seconds to propagate to all edge locations)"
echo ""
echo "Deployed. Live at: $SITE_URL"
