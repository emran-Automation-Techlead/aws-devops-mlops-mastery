# Every prediction from serving/app.py lands here (see _log_prediction).
# On-demand billing, not provisioned capacity - prediction volume here is
# spiky and low enough that paying per-request beats guessing at a
# provisioned throughput and either overpaying or throttling.
resource "aws_dynamodb_table" "prediction_log" {
  name         = "${var.project_name}-prediction-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "prediction_id"

  attribute {
    name = "prediction_id"
    type = "S"
  }

  # TTL keeps this table from growing forever - prediction logs older
  # than 30 days aren't useful for drift detection (which only looks at
  # the last few hours) and shouldn't cost storage indefinitely.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.tags
}
