resource "aws_ecr_repository" "model_server" {
  name                 = "model-server"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "model_server" {
  repository = aws_ecr_repository.model_server.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 15 tagged images (stable, candidate, and commit-SHA tags accumulate quickly with frequent retraining)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "stable", "candidate", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 15
        }
        action = { type = "expire" }
      }
    ]
  })
}
