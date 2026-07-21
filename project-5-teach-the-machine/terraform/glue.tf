data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.project_name}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name = "${var.project_name}-glue-s3-access"
  role = aws_iam_role.glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
      }
    ]
  })
}

resource "aws_s3_object" "glue_job_script" {
  bucket = aws_s3_bucket.data.id
  key    = "glue-scripts/feature_engineering_glue_job.py"
  source = "../features/feature_engineering_glue_job.py"
  etag   = filemd5("../features/feature_engineering_glue_job.py")
}

resource "aws_glue_job" "feature_engineering" {
  name              = "${var.project_name}-feature-engineering"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 30
  tags              = local.tags

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data.bucket}/glue-scripts/feature_engineering_glue_job.py"
    python_version  = "3"
  }

  default_arguments = {
    "--input_path"   = "s3://${aws_s3_bucket.data.bucket}/raw/transactions.csv"
    "--output_path"  = "s3://${aws_s3_bucket.data.bucket}/features/"
    "--job-language" = "python"
  }
}

resource "aws_glue_catalog_database" "fraud_detection" {
  name = "fraud_detection"
}

# Crawler + a catalog table is what makes the engineered Parquet output
# queryable from Athena in plain SQL - useful for ad-hoc "how many
# high-velocity transactions did we see last week" questions without
# spinning up a notebook.
resource "aws_glue_crawler" "features" {
  name          = "${var.project_name}-features-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.fraud_detection.name
  tags          = local.tags

  s3_target {
    path = "s3://${aws_s3_bucket.data.bucket}/features/"
  }

  schedule = "cron(0 4 * * ? *)" # re-crawl daily at 4am - after any overnight retrain would have written new features
}

resource "aws_athena_workgroup" "fraud_detection" {
  name = "${var.project_name}-workgroup"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.data.bucket}/athena-results/"
    }
  }

  tags = local.tags
}

resource "aws_athena_named_query" "sample_query" {
  name      = "fraud-rate-by-merchant"
  workgroup = aws_athena_workgroup.fraud_detection.name
  database  = aws_glue_catalog_database.fraud_detection.name
  query     = <<-SQL
    SELECT
      CASE
        WHEN merchant_grocery = 1 THEN 'grocery'
        WHEN merchant_electronics = 1 THEN 'electronics'
        WHEN merchant_travel = 1 THEN 'travel'
        WHEN merchant_gas = 1 THEN 'gas'
        WHEN merchant_restaurant = 1 THEN 'restaurant'
        WHEN merchant_online = 1 THEN 'online'
        ELSE 'unknown'
      END AS merchant_category,
      COUNT(*) AS total_transactions,
      SUM(is_fraud) AS fraud_count,
      ROUND(100.0 * SUM(is_fraud) / COUNT(*), 2) AS fraud_rate_pct
    FROM features
    GROUP BY 1
    ORDER BY fraud_rate_pct DESC
  SQL
}
