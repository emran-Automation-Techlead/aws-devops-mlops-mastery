####################################################################
# CI/CD for this project reuses the SAME GitHub connection Project 2
# already set up and authorized (Terraform states are per-project/
# per-folder here, so it's passed in as a variable rather than
# referenced directly - a real "shared services" pattern: one connection,
# many pipelines). Run:
#   terraform -chdir=../../project-2-robot-builder/terraform output github_connection_arn
# and pass the result as -var="github_connection_arn=...". No second
# manual OAuth authorization needed.
####################################################################

variable "github_connection_arn" {
  description = "CodeStar Connection ARN from Project 2 (already authorized) - see comment above"
  type        = string
}

variable "github_repo" {
  type    = string
  default = "emran-Automation-Techlead/aws-devops-mlops-mastery"
}

variable "github_branch" {
  type    = string
  default = "master"
}

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

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.app_name}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "codebuild_policy" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:/aws/codebuild/${var.app_name}*"]
  }
  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.pipeline_artifacts.arn}/*"]
  }
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [for repo in aws_ecr_repository.service : repo.arn]
  }
  statement {
    sid    = "ECSDeploy"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = [for svc in aws_ecs_service.service : svc.id]
  }
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name   = "${var.app_name}-codebuild-policy"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_policy.json
}

resource "aws_codebuild_project" "app" {
  name         = var.app_name
  description  = "Builds 3 Docker images, pushes to ECR, rolls out on ECS"
  service_role = aws_iam_role.codebuild.arn
  tags         = local.tags

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
    # Docker builds need to run their own inner Docker daemon inside the
    # CodeBuild container - this is the one flag that makes `docker build`
    # work at all in CodeBuild.
    privileged_mode = true

    environment_variable {
      name  = "ECR_REGISTRY"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "project-3-box-everything/buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.app_name}"
    }
  }
}

data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${var.app_name}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "codepipeline_policy" {
  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketVersioning",
    ]
    resources = [
      aws_s3_bucket.pipeline_artifacts.arn,
      "${aws_s3_bucket.pipeline_artifacts.arn}/*",
    ]
  }
  statement {
    sid       = "GitHubConnection"
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = [var.github_connection_arn]
  }
  statement {
    sid    = "CodeBuild"
    effect = "Allow"
    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]
    resources = [aws_codebuild_project.app.arn]
  }
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name   = "${var.app_name}-codepipeline-policy"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline_policy.json
}

resource "aws_codepipeline" "app" {
  name     = var.app_name
  role_arn = aws_iam_role.codepipeline.arn
  tags     = local.tags

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceOutput"]

      configuration = {
        ConnectionArn    = var.github_connection_arn
        FullRepositoryId = var.github_repo
        BranchName       = var.github_branch
      }
    }
  }

  # No separate Deploy stage - CodeBuild's buildspec pushes to ECR AND
  # calls ecs update-service in the same run. Contrast with Project 2,
  # where Build and Deploy were split because CodeDeploy needed its own
  # stage to manage blue/green traffic shifting.
  stage {
    name = "BuildAndDeploy"
    action {
      name             = "BuildAndDeploy"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["BuildOutput"]

      configuration = {
        ProjectName = aws_codebuild_project.app.name
      }
    }
  }
}
