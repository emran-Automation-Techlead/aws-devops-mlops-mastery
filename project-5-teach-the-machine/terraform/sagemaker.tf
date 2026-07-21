data "aws_iam_policy_document" "sagemaker_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

# One execution role, used both by Training/Processing Jobs at runtime
# AND to run the Pipeline itself. AmazonSageMakerFullAccess is broader
# than a hardened production setup should use - the honest scoped-down
# version would split this into a training role (S3 read on data/,
# S3 write on models/, ECR pull, CloudWatch Logs) and a separate
# lighter pipeline-orchestration role. Using the managed policy here
# keeps the Terraform focused on the pipeline architecture rather than
# a wall of IAM statements - tighten this before using it with real
# production data.
resource "aws_iam_role" "sagemaker_execution" {
  name               = "${var.project_name}-sagemaker-execution"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "sagemaker_execution_managed" {
  role       = aws_iam_role.sagemaker_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

data "aws_iam_policy_document" "sagemaker_s3_access" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/*",
      aws_s3_bucket.models.arn,
      "${aws_s3_bucket.models.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "sagemaker_s3_access" {
  name   = "${var.project_name}-sagemaker-s3-access"
  role   = aws_iam_role.sagemaker_execution.id
  policy = data.aws_iam_policy_document.sagemaker_s3_access.json
}

# Model Registry: every registered model version lives in ONE group,
# grouped by name so the Registry shows the full version history of
# "the fraud model" over time rather than disconnected one-off models.
resource "aws_sagemaker_model_package_group" "fraud_detection" {
  model_package_group_name        = "fraud-detection-models"
  model_package_group_description = "Fraud detection models - see evaluation/evaluate.py for the selection/registration logic"
  tags                            = local.tags
}

# Feature Store: online store for low-latency single-record reads
# (a real-time endpoint fetching one transaction's features at inference
# time), offline store to S3/Parquet for batch training and Athena
# queries - the same engineered features serve BOTH use cases from one
# definition instead of two separate systems drifting apart.
resource "aws_sagemaker_feature_group" "transactions" {
  feature_group_name             = "fraud-transactions"
  record_identifier_feature_name = "transaction_id"
  event_time_feature_name        = "event_time"
  role_arn                       = aws_iam_role.sagemaker_execution.arn

  feature_definition {
    feature_name = "transaction_id"
    feature_type = "String"
  }
  feature_definition {
    feature_name = "event_time"
    feature_type = "String"
  }
  feature_definition {
    feature_name = "amount_log"
    feature_type = "Fractional"
  }
  feature_definition {
    feature_name = "hour_sin"
    feature_type = "Fractional"
  }
  feature_definition {
    feature_name = "hour_cos"
    feature_type = "Fractional"
  }
  feature_definition {
    feature_name = "txn_count_last_hour"
    feature_type = "Integral"
  }
  feature_definition {
    feature_name = "distance_from_home_km"
    feature_type = "Fractional"
  }
  feature_definition {
    feature_name = "card_age_days"
    feature_type = "Integral"
  }

  online_store_config {
    enable_online_store = true
  }

  offline_store_config {
    s3_storage_config {
      s3_uri = "s3://${aws_s3_bucket.data.bucket}/feature-store/"
    }
  }

  tags = local.tags
}
