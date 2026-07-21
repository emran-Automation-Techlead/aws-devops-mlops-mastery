# MLflow tracking server, deployed onto Project 4's EKS cluster rather
# than standing up new compute for it - the whole point of building a
# shared cluster earlier in this series. Backend store: SQLite on a PVC
# (simplest thing that persists across pod restarts; a team running this
# for real would use RDS Postgres instead, for concurrent-write safety -
# noted rather than glossed over, since SQLite's single-writer limitation
# is a real constraint at higher training concurrency than this project
# needs). Artifact store: S3, via IRSA - no static credentials.

resource "kubernetes_namespace" "mlflow" {
  metadata {
    name = "mlflow"
  }
}

module "mlflow_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.project_name}-mlflow"

  role_policy_arns = {
    s3_artifacts = aws_iam_policy.mlflow_s3_artifacts.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["mlflow:mlflow"]
    }
  }

  tags = local.tags
}

resource "aws_iam_policy" "mlflow_s3_artifacts" {
  name = "${var.project_name}-mlflow-s3-artifacts"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.models.arn, "${aws_s3_bucket.models.arn}/mlflow-artifacts/*"]
      }
    ]
  })
}

resource "kubernetes_service_account" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace.mlflow.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.mlflow_irsa.iam_role_arn
    }
  }
}

resource "kubernetes_persistent_volume_claim" "mlflow_db" {
  metadata {
    name      = "mlflow-db"
    namespace = kubernetes_namespace.mlflow.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "gp3"
    resources {
      requests = { storage = "5Gi" }
    }
  }
}

resource "kubernetes_deployment" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace.mlflow.metadata[0].name
    labels    = { app = "mlflow" }
  }
  spec {
    replicas = 1 # SQLite backend means this can't be scaled horizontally - see the comment at the top of this file
    selector {
      match_labels = { app = "mlflow" }
    }
    template {
      metadata {
        labels = { app = "mlflow" }
      }
      spec {
        service_account_name = kubernetes_service_account.mlflow.metadata[0].name
        container {
          name    = "mlflow"
          image   = "ghcr.io/mlflow/mlflow:v2.16.2"
          command = ["mlflow"]
          args = [
            "server",
            "--host", "0.0.0.0",
            "--port", "5000",
            "--backend-store-uri", "sqlite:////mlflow-data/mlflow.db",
            "--default-artifact-root", "s3://${aws_s3_bucket.models.bucket}/mlflow-artifacts/",
          ]
          port {
            container_port = 5000
          }
          volume_mount {
            name       = "mlflow-data"
            mount_path = "/mlflow-data"
          }
          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "500m", memory = "1Gi" }
          }
        }
        volume {
          name = "mlflow-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mlflow_db.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace.mlflow.metadata[0].name
  }
  spec {
    selector = { app = "mlflow" }
    port {
      port        = 5000
      target_port = 5000
    }
  }
}

# Public ALB, deliberately - SageMaker Training Jobs run in an AWS-managed
# environment outside this VPC by default, so the simplest way for them
# to reach MLflow is over the public internet. A production setup would
# instead run training jobs with VPC config pointed at this cluster's VPC
# and use an internal ALB - simpler for a teaching project, called out
# here rather than left unexplained.
resource "kubernetes_ingress_v1" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace.mlflow.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                = "alb"
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/health"
    }
  }
  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.mlflow.metadata[0].name
              port {
                number = 5000
              }
            }
          }
        }
      }
    }
  }
}
