variable "aws_region" {
  description = "Region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Short name used to prefix/tag every resource"
  type        = string
  default     = "robot-builder"
}

variable "environment" {
  description = "Environment tag, e.g. dev, prod"
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 instance type - t3.micro is free-tier eligible"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 1
}

variable "asg_max_size" {
  type    = number
  default = 2
}

variable "asg_desired_capacity" {
  type    = number
  default = 1
}

variable "github_repo" {
  description = "owner/repo of the monorepo this pipeline watches"
  type        = string
  default     = "emran-Automation-Techlead/aws-devops-mlops-mastery"
}

variable "github_branch" {
  description = "Branch CodePipeline deploys from"
  type        = string
  default     = "master"
}

variable "alert_email" {
  description = "Email to notify on the error-rate CloudWatch alarm. Leave blank to skip the subscription."
  type        = string
  default     = ""
}

locals {
  tags = {
    Project     = var.app_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
