data "aws_caller_identity" "current" {}

locals {
  # Project 4's EKS module (enable_irsa = true) already created the IAM
  # OIDC identity provider for this cluster - this reconstructs its ARN
  # from the cluster's own OIDC issuer URL rather than re-creating it
  # (creating a second OIDC provider for the same issuer URL would
  # conflict).
  oidc_issuer_no_prefix = replace(data.aws_eks_cluster.existing.identity[0].oidc[0].issuer, "https://", "")
  oidc_provider_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_issuer_no_prefix}"
}

# IRSA role for the model-server ServiceAccount (helm/model-server/templates/serviceaccount.yaml)
# - read-only access to the model artifacts bucket, nothing else. This
# is what the initContainer in deployment.yaml uses to download
# model.tar.gz at pod startup.
module "model_server_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.project_name}-model-server"

  role_policy_arns = {
    s3_read = aws_iam_policy.model_server_s3_read.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["dev:model-server", "staging:model-server", "production:model-server"]
    }
  }

  tags = local.tags
}

resource "aws_iam_policy" "model_server_s3_read" {
  name = "${var.project_name}-model-server-s3-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.models.arn}/*"]
      }
    ]
  })
}
