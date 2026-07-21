# One repository per service - keeps permissions, lifecycle policies, and
# vulnerability scan results scoped per-service instead of one shared
# repo where a policy change affects all 3 at once.
resource "aws_ecr_repository" "service" {
  for_each = toset(local.services)

  name                 = "${var.app_name}-${each.value}"
  image_tag_mutability = "MUTABLE" # allows re-pushing "latest" on every build

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# Without this, every push (three tags per deploy, per deploy-ecs.sh)
# accumulates forever and you pay storage for years of stale images.
# Keep the last 10 tagged images per service; untagged ones (orphaned by
# a repushed "latest" tag) expire after 1 day.
resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = toset(local.services)
  repository = aws_ecr_repository.service[each.value].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
