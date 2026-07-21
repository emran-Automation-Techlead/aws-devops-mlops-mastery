output "aws_region" {
  value = var.aws_region
}

output "alb_dns_name" {
  description = "Base URL - try /users, /products, /orders"
  value       = "http://${aws_lb.app.dns_name}"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.service : k => v.repository_url }
}
