# What External Secrets Operator (deployed via Helm - see
# k8s/manifests/external-secrets) syncs into the cluster as a native
# Kubernetes Secret. The app never touches Secrets Manager's API
# directly - it just reads an env var, same as any other k8s Secret.
resource "aws_secretsmanager_secret" "app_config" {
  name        = "${var.cluster_name}/app-config"
  description = "Synced into the cluster by External Secrets Operator"
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id = aws_secretsmanager_secret.app_config.id
  secret_string = jsonencode({
    example_api_key = "replace-me-with-a-real-value"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
