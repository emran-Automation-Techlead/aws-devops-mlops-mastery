output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "load_balancer_controller_role_arn" {
  value = module.load_balancer_controller_irsa.iam_role_arn
}

output "cluster_autoscaler_role_arn" {
  value = module.cluster_autoscaler_irsa.iam_role_arn
}

output "external_secrets_role_arn" {
  value = module.external_secrets_irsa.iam_role_arn
}
