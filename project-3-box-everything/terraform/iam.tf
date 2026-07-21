data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: what ECS itself needs to LAUNCH the container (pull the
# image from ECR, ship logs to CloudWatch). The container's own code
# never uses this role.
resource "aws_iam_role" "execution" {
  name               = "${var.app_name}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: what the APPLICATION CODE running inside the container is
# allowed to do at runtime (call other AWS APIs). Deliberately separate
# from the execution role above - the container pulling its own image is
# a different trust boundary than the container calling, say, Secrets
# Manager once it's running.
resource "aws_iam_role" "task" {
  name               = "${var.app_name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "task_permissions" {
  statement {
    sid    = "ReadAppSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = ["arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.app_name}/*"]
  }
}

resource "aws_iam_role_policy" "task_permissions" {
  name   = "${var.app_name}-task-permissions"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_permissions.json
}
