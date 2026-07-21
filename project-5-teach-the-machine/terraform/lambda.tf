data "archive_file" "drift_detector" {
  type        = "zip"
  source_file = "../monitoring/drift_detector.py"
  output_path = "${path.module}/.build/drift_detector.zip"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "drift_detector" {
  name               = "${var.project_name}-drift-detector"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "drift_detector_logs" {
  role       = aws_iam_role.drift_detector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "drift_detector_permissions" {
  statement {
    sid       = "ReadBaseline"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.data.arn}/monitoring/*"]
  }
  statement {
    sid       = "ScanPredictionLog"
    effect    = "Allow"
    actions   = ["dynamodb:Scan"]
    resources = [aws_dynamodb_table.prediction_log.arn]
  }
  statement {
    sid       = "PublishMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource-level restriction
  }
  statement {
    sid       = "PublishAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.drift_alerts.arn]
  }
  statement {
    sid       = "TriggerRetraining"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.retraining.arn]
  }
}

resource "aws_iam_role_policy" "drift_detector_permissions" {
  name   = "${var.project_name}-drift-detector-permissions"
  role   = aws_iam_role.drift_detector.id
  policy = data.aws_iam_policy_document.drift_detector_permissions.json
}

resource "aws_lambda_function" "drift_detector" {
  function_name    = "${var.project_name}-drift-detector"
  role             = aws_iam_role.drift_detector.arn
  handler          = "drift_detector.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.drift_detector.output_path
  source_code_hash = data.archive_file.drift_detector.output_base64sha256
  tags             = local.tags

  # numpy isn't in the standard Lambda runtime - a real deployment adds a
  # Lambda Layer (e.g. AWS's published numpy/pandas layer, or a custom
  # one built via `pip install -t` and zipped) here. Noted rather than
  # glossed over: this function will fail on `import numpy` until that
  # layer is attached.
  # layers = ["arn:aws:lambda:${var.aws_region}:336392948345:layer:AWSSDKPandas-Python312:latest"]

  environment {
    variables = {
      PSI_THRESHOLD        = tostring(var.psi_drift_threshold)
      BASELINE_BUCKET      = aws_s3_bucket.data.bucket
      BASELINE_KEY         = "monitoring/baseline_stats.json"
      PREDICTION_LOG_TABLE = aws_dynamodb_table.prediction_log.name
      SNS_TOPIC_ARN        = aws_sns_topic.drift_alerts.arn
      STATE_MACHINE_ARN    = aws_sfn_state_machine.retraining.arn
      RAW_DATA_S3_URI      = "s3://${aws_s3_bucket.data.bucket}/raw/transactions.csv"
      LOOKBACK_HOURS       = "6"
    }
  }
}

resource "aws_cloudwatch_event_rule" "drift_check_schedule" {
  name                = "${var.project_name}-drift-check"
  schedule_expression = var.drift_check_schedule
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "drift_check" {
  rule = aws_cloudwatch_event_rule.drift_check_schedule.name
  arn  = aws_lambda_function.drift_detector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_detector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.drift_check_schedule.arn
}
