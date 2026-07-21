data "aws_iam_policy_document" "sfn_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn_retraining" {
  name               = "${var.project_name}-retraining-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "sfn_retraining_permissions" {
  statement {
    sid    = "RunPipeline"
    effect = "Allow"
    actions = [
      "sagemaker:StartPipelineExecution",
      "sagemaker:DescribePipelineExecution",
      "sagemaker:StopPipelineExecution",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "SyncIntegrationEvents"
    effect = "Allow"
    # The ".sync" suffix on the SageMaker StartPipelineExecution task in
    # the ASL definition means Step Functions waits for the pipeline to
    # actually finish, not just accept the start request - internally it
    # does this via a managed EventBridge rule, which needs these 3
    # permissions to set up. Easy to miss; the state machine fails
    # immediately without them, with an error that doesn't obviously
    # point at "add these IAM permissions."
    actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
    resources = ["*"]
  }
  statement {
    sid       = "PublishAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.drift_alerts.arn]
  }
}

resource "aws_iam_role_policy" "sfn_retraining_permissions" {
  name   = "${var.project_name}-retraining-sfn-permissions"
  role   = aws_iam_role.sfn_retraining.id
  policy = data.aws_iam_policy_document.sfn_retraining_permissions.json
}

resource "aws_sfn_state_machine" "retraining" {
  name     = "${var.project_name}-retraining"
  role_arn = aws_iam_role.sfn_retraining.arn
  tags     = local.tags

  definition = templatefile("../pipelines/step_functions/retraining_state_machine.asl.json", {
    DriftAlertsTopicArn = aws_sns_topic.drift_alerts.arn
  })
}
