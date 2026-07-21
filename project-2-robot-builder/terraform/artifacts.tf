resource "random_id" "artifact_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket = "${var.app_name}-artifacts-${random_id.artifact_suffix.hex}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Demonstrates the pattern: the app should read config like this from
# Secrets Manager at runtime rather than baking it into the code or an
# .env file that ends up in git. Not currently wired into app.js (the
# task API doesn't need a secret yet) - this exists so the pattern is
# here to extend when a real credential shows up (Project 5's SageMaker
# endpoint config, for instance).
resource "aws_secretsmanager_secret" "app_config" {
  name        = "${var.app_name}/app-config"
  description = "Runtime configuration for the robot-builder app"
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
