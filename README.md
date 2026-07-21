# ☁️ AWS DevOps → MLOps Mastery

Five progressive, end-to-end projects that take you from "I've never touched
the cloud" to "I run a self-healing AI system in production." Each project
builds on the last — same AWS account, growing skillset, growing architecture.

Written so a smart 14-year-old could follow the reasoning, but every file is
production-grade: real IAM policies, real error handling, real security
practices. No toy examples.

## The Path

| # | Project | Big Idea | Status |
|---|---------|----------|--------|
| 1 | [Hello Cloud](project-1-hello-cloud/) | Deploy a static site to S3 + CloudFront + Route 53 + ACM | ✅ Built |
| 2 | Robot Builder | CI/CD pipeline: GitHub Actions → CodeBuild → CodeDeploy, zero-downtime | ⏳ Next |
| 3 | Box Everything | Docker microservices on ECR + ECS Fargate | ⏳ Planned |
| 4 | Command the Fleet | Kubernetes on EKS with Helm, HPA, Prometheus/Grafana/Loki | ⏳ Planned |
| 5 | Teach the Machine | End-to-end MLOps: SageMaker → MLflow → EKS → drift detection → auto-retraining | ⏳ Planned |

## How to use this repo

Each `project-N-*/` folder is self-contained: its own README with the full
build (architecture, cost estimate, step-by-step, verification checklist,
common mistakes), plus the actual code/Terraform/scripts to run it.

**Before running anything against real AWS**: these projects create real,
billed resources. Every project's README has a cost estimate and a "how to
tear it down" step — read both before you `terraform apply`.

## Prerequisites (all projects)

- AWS account with a non-root IAM user (Project 1 walks through setting this up)
- AWS CLI v2, configured with valid credentials (`aws sts get-caller-identity` should succeed)
- Terraform >= 1.5
- Git

Project-specific tools (Docker, kubectl, Helm, eksctl, SageMaker SDK) are
listed in each project's own Prerequisites section.
