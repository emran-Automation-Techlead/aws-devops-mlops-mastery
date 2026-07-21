variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "command-the-fleet"
}

variable "cluster_version" {
  description = "Kubernetes version - check AWS's EKS release calendar before bumping; old versions get deprecated on a schedule"
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "developer_iam_role_arn" {
  description = "IAM role your developers assume (e.g. via SSO) - mapped to the 'developers' Kubernetes group via an EKS access entry. Leave blank to skip this mapping."
  type        = string
  default     = ""
}

locals {
  tags = {
    Project     = var.cluster_name
    ManagedBy   = "terraform"
    Environment = "shared" # this ONE cluster hosts dev/staging/production namespaces - see k8s/manifests
  }
}
