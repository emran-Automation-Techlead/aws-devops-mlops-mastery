## PROJECT 4: "Command the Fleet" — Kubernetes on AWS EKS with Full Observability

### 🧠 What Is This?

ECS (Project 3) is great when you have a handful of services. But what if
you have 100 different services, each needing different amounts of CPU
and memory, with complex dependencies between them? You need a conductor
for your orchestra of containers. That conductor is **Kubernetes**.

Imagine you manage a massive food court with 50 different restaurants.
Each restaurant (container) needs tables (CPU), electricity (memory), and
ingredients (storage). If one restaurant gets super busy, you need to
open more tables automatically. If a restaurant's oven breaks, you swap
it instantly without customers noticing. **Kubernetes** is the master
food court manager doing all of this automatically, 24/7 — and **EKS**
is AWS running that manager for you so you never have to install or
patch it yourself.

By the end, the same 3 services from Project 3 run on a real EKS
cluster, in 3 separate environments (dev/staging/production), with
automatic scaling at both the pod level and the node level, full metrics
and log observability, and access control that physically prevents
"developers" from touching production.

### 🗺️ Architecture Diagram

See [`docs/architecture.md`](docs/architecture.md) for the full diagram
and the three trust boundaries this project relies on. Short version:
one EKS cluster, one custom VPC (private subnets for worker nodes), one
shared ALB routing into whichever namespace's Ingress matches, and a
monitoring namespace watching all of it.

### 💰 AWS Cost Estimate

| Service | Free Tier | Beyond Free Tier |
|---|---|---|
| EKS control plane | None | **$73/month flat**, regardless of cluster size |
| EC2 nodes (2x t3.medium) | 750 hrs/month for ONE t2.micro only — not enough for a real node group | ~$60/month for 2x t3.medium continuously |
| NAT Gateway | None | ~$32/month + data processing |
| Application Load Balancer | None | ~$16/month + LCU usage |
| EBS (Prometheus/Grafana/Loki PVCs, ~40GB total) | 30GB free (12 months) | ~$0.08/GB-month beyond that |
| Secrets Manager | Same as prior projects | $0.40/secret/month |

**Realistic total running continuously: ~$185–210/month.** This is, by
a wide margin, the most expensive project in the series — the $73 EKS
control plane fee alone is fixed cost regardless of how small your
workload is. **This is the clearest "tear it down when not actively
learning" project in the series** — `terraform destroy` after each study
session unless you're actively using it.

### 🛠️ Tools & Why We Use Each One

| Tool | Problem It Solves | Alternative Without It |
|---|---|---|
| **EKS** | Managed Kubernetes control plane — AWS patches/scales/secures it | Self-managing the control plane (etcd, API server HA) is a full-time job by itself |
| **Helm** | Templated, versioned, environment-parameterized Kubernetes manifests | Copy-pasting slightly-different YAML for dev/staging/production, drifting apart over time |
| **AWS Load Balancer Controller** | Kubernetes `Ingress` objects provision REAL ALBs automatically | Manually creating/updating ALB target groups every time a service changes |
| **Cluster Autoscaler** | Adds/removes EC2 nodes so pods always have somewhere to schedule | HPA scales pods but they sit `Pending` forever once nodes are full |
| **External Secrets Operator** | Kubernetes-native Secrets, populated FROM Secrets Manager, auto-refreshed | Secrets baked into images or manually `kubectl create secret`'d and never rotated |
| **RBAC + EKS Access Entries** | IAM identity → Kubernetes permissions, enforced by the API server itself | A shared kubeconfig with cluster-admin for everyone — no real access control |
| **Prometheus + Grafana** | Metrics collection + dashboards, the de facto Kubernetes-native standard | CloudWatch Container Insights alone lacks the query flexibility (PromQL) and free dashboarding |
| **Loki + Promtail** | Centralized logs, queried with the same label model as Prometheus | `kubectl logs` one pod at a time, logs gone the moment a pod is deleted |

### 📋 Prerequisites

- Everything from [Project 3](../project-3-box-everything/) — the same
  3 ECR repos are reused here, no rebuild needed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm 3](https://helm.sh/docs/intro/install/) installed
- Comfort with `kubectl` basics (`get`, `describe`, `logs`) helps but
  isn't required — every command you need is in this README

### 🚀 Step-by-Step Build

#### Step 1 — Understand what's different from Project 3

Same 3 FastAPI services, same Docker images (Project 3's ECR repos, no
rebuild) — but now each also exposes `GET /metrics` (added via
`prometheus-fastapi-instrumentator`, 3 lines added to each service's
`main.py`). Everything else about *how they run* changes: Fargate tasks
become Kubernetes Pods managed by Deployments; Terraform-defined ALB
target groups become a Kubernetes `Ingress`; ECS's rolling update becomes
a Kubernetes `RollingUpdate` strategy.

#### Step 2 — Provision the cluster and every add-on

```bash
cd project-4-command-the-fleet
chmod +x scripts/setup-eks.sh
./scripts/setup-eks.sh
```

This runs `terraform apply` (VPC, EKS cluster, managed node group, 3
IRSA roles — 15-20 minutes, mostly the EKS control plane provisioning),
configures `kubectl`, then installs, in dependency order: namespaces +
RBAC, the AWS Load Balancer Controller, Cluster Autoscaler, External
Secrets Operator, Prometheus + Grafana, Loki, and finally the
microservices Helm chart into all 3 namespaces.

#### Step 3 — Verify the cluster and namespaces

```bash
kubectl get nodes
kubectl get namespaces
kubectl get pods -n dev
kubectl get pods -n monitoring
```

#### Step 4 — Get the ALB URLs and test each environment

```bash
kubectl get ingress -n dev
kubectl get ingress -n staging
kubectl get ingress -n production
```
Each namespace gets its **own ALB** (different `albGroupName` per
`values-<env>.yaml` — deliberately, so a bad deploy in `dev` can never
affect `production`'s load balancer). Test one:
```bash
DEV_ALB=$(kubectl get ingress microservices -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl "http://$DEV_ALB/users"
curl "http://$DEV_ALB/products"
curl -X POST "http://$DEV_ALB/orders" -H "Content-Type: application/json" -d '{"user_id":1,"product_id":1,"quantity":1}'
```

#### Step 5 — Open Grafana and see real RED-method metrics

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```
Open `http://localhost:3000` (user `admin`, password from
`kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d`).
The **"Microservices - RED Method"** dashboard is already provisioned —
Rate, Errors, Duration per service, plus pod count per namespace as an
HPA-activity proxy. Generate some traffic first (Step 4's curl commands,
looped a few times) so the graphs have something to show.

#### Step 6 — Confirm RBAC actually blocks production access

If you set `developer_iam_role_arn` in Terraform, have someone who
assumes that role try:
```bash
kubectl get pods -n dev          # works - Role bound here
kubectl get pods -n staging       # works - Role bound here
kubectl get pods -n production    # Error: pods is forbidden - no RoleBinding exists here
```
The third command failing with `Forbidden`, not a connection error or a
timeout, is the proof this is enforced by the API server itself.

#### Step 7 — Demonstrate the Cluster Autoscaler adding nodes

```bash
kubectl get nodes -w   # leave running in one terminal

# In another terminal, force way more replicas than current nodes can hold
kubectl scale deployment user-service -n production --replicas=15
```
Watch new pods sit `Pending` (`kubectl get pods -n production`), then a
new node appear in the first terminal a minute or two later as Cluster
Autoscaler reacts. Scale back down afterward:
```bash
kubectl scale deployment user-service -n production --replicas=3
```

#### Step 8 — Demonstrate zero-downtime rolling deployment

```bash
kubectl set image deployment/user-service user-service=<ECR_REGISTRY>/box-everything-user-service:v1.0.1 -n production
kubectl rollout status deployment/user-service -n production
```
While that's running, loop curl against the production ALB the same way
as Project 2/3's zero-downtime demos — `maxUnavailable: 0` in the
Deployment's `RollingUpdate` strategy (see
`helm/microservices/templates/deployment.yaml`) guarantees no dip below
the configured replica count during the rollout.

### ✅ Verification Checklist

- [ ] `kubectl get nodes` shows 2+ nodes in `Ready` state
- [ ] All 3 services have running, `Ready` pods in `dev`, `staging`, and `production`
- [ ] Each namespace's Ingress has its own ALB hostname
- [ ] `curl .../users`, `/products`, `/orders` work against at least one environment
- [ ] Grafana's RED dashboard shows non-zero request rate after generating traffic
- [ ] Loki shows logs when queried from Grafana's Explore view (`{namespace="production"}`)
- [ ] The `developers` IAM role (if configured) can list pods in dev/staging but gets `Forbidden` in production
- [ ] Scaling a deployment past node capacity triggers a new node within a few minutes
- [ ] A rolling image update completes with zero failed requests in a concurrent curl loop

### 🔥 Common Mistakes & How to Fix Them

1. **Ingress created, but no ALB ever appears.**
   Almost always the subnet tags in `vpc.tf`
   (`kubernetes.io/role/elb` / `kubernetes.io/role/internal-elb`) are
   missing or on the wrong subnets — the AWS Load Balancer Controller
   uses these tags to auto-discover where to put the ALB. Check
   `kubectl logs -n kube-system deployment/aws-load-balancer-controller`
   for the specific rejection reason.

2. **Pods stuck in `ImagePullBackOff`.**
   The node's IAM role can't pull from ECR, or the image tag doesn't
   exist. Confirm with `kubectl describe pod <pod> -n <namespace>` — the
   Events section names the exact failure. Cross-check the tag exists:
   `aws ecr describe-images --repository-name box-everything-user-service`.

3. **HPA shows `<unknown>` for current CPU utilization forever.**
   The Metrics Server isn't installed — EKS doesn't ship it by default.
   Install it: `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml`.

4. **ExternalSecret never populates the Kubernetes Secret.**
   Check `kubectl describe externalsecret app-config -n <namespace>` for
   the sync status/error. Usually either the IRSA role ARN wasn't
   annotated on the `external-secrets` ServiceAccount correctly, or the
   secret name in Secrets Manager doesn't match `remoteRef.key` in
   `externalsecret.yaml`.

5. **`developers` group has NO access anywhere, including dev/staging.**
   The IAM → Kubernetes group mapping (`access_entries` in
   `eks-cluster.tf`) requires `developer_iam_role_arn` to actually be
   set — it defaults to empty (mapping skipped) specifically so
   `terraform apply` doesn't fail for someone who hasn't set up that IAM
   role yet. Pass `-var="developer_iam_role_arn=arn:aws:iam::...:role/..."`
   once you have one.

### 🔗 How This Connects to the Next Project

Everything so far has been about *shipping and running* code reliably.
Project 5 ("Teach the Machine") is a different kind of workload
entirely: a machine learning model that needs training, evaluation, and
*retraining* as real-world data drifts — using SageMaker for the ML-
specific parts, but deploying the final model server on this exact EKS
cluster, behind an Ingress, monitored by this exact Prometheus/Grafana
stack. The DevOps foundation doesn't get thrown away for MLOps — it gets
reused.
