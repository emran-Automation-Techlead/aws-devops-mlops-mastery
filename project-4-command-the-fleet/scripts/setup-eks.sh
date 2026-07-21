#!/usr/bin/env bash
#
# Provisions the EKS cluster and installs every cluster add-on this
# project depends on, in the order that actually works (the AWS Load
# Balancer Controller needs its IRSA role to exist before it can start;
# the microservices chart needs the Ingress class and namespaces to
# exist before IT can start, etc.)
#
# Usage: ./setup-eks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/infrastructure/eks"

echo "==> Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not configured or are invalid."
  exit 1
fi

echo "==> Provisioning VPC + EKS cluster + node group + IRSA roles (this takes 15-20 minutes, mostly the EKS control plane)..."
terraform -chdir="$TERRAFORM_DIR" init
terraform -chdir="$TERRAFORM_DIR" apply -auto-approve

CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_name)
AWS_REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region)
LB_ROLE_ARN=$(terraform -chdir="$TERRAFORM_DIR" output -raw load_balancer_controller_role_arn)
CA_ROLE_ARN=$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_autoscaler_role_arn)
ES_ROLE_ARN=$(terraform -chdir="$TERRAFORM_DIR" output -raw external_secrets_role_arn)
VPC_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_id)

echo "==> Configuring kubectl..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo "==> Creating namespaces and RBAC..."
kubectl apply -f "$PROJECT_DIR/k8s/manifests/namespaces.yaml"
kubectl apply -f "$PROJECT_DIR/k8s/manifests/rbac/"

echo "==> Adding Helm repos..."
helm repo add eks https://aws.github.io/eks-charts
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo add external-secrets https://charts.external-secrets.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo "==> Installing AWS Load Balancer Controller..."
kubectl create serviceaccount -n kube-system aws-load-balancer-controller --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount -n kube-system aws-load-balancer-controller \
  eks.amazonaws.com/role-arn="$LB_ROLE_ARN" --overwrite
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set vpcId="$VPC_ID"

echo "==> Installing Cluster Autoscaler..."
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  -f "$PROJECT_DIR/k8s/autoscaling/cluster-autoscaler-values.yaml" \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$AWS_REGION" \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$CA_ROLE_ARN"

echo "==> Installing External Secrets Operator..."
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set serviceAccount.name=external-secrets \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ES_ROLE_ARN"

echo "==> Installing Prometheus + Grafana..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "$PROJECT_DIR/k8s/monitoring/prometheus-values.yaml" \
  --set-file grafana.dashboards.default.red-method.json="$PROJECT_DIR/k8s/monitoring/grafana-dashboard-red.json"

echo "==> Installing Loki..."
helm upgrade --install loki grafana/loki-stack \
  -n monitoring \
  -f "$PROJECT_DIR/k8s/monitoring/loki-values.yaml"

echo "==> Deploying microservices to dev, staging, and production..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

for ENV in dev staging production; do
  helm upgrade --install microservices "$PROJECT_DIR/helm/microservices" \
    --namespace "$ENV" \
    -f "$PROJECT_DIR/helm/microservices/values.yaml" \
    -f "$PROJECT_DIR/helm/microservices/values-${ENV}.yaml" \
    --set ecrRegistry="$ECR_REGISTRY" \
    --set awsRegion="$AWS_REGION"
done

echo ""
echo "==> Done. Get the ALB URLs with:"
echo "    kubectl get ingress -n dev"
echo "    kubectl get ingress -n staging"
echo "    kubectl get ingress -n production"
echo "==> Grafana admin password:"
echo "    kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
