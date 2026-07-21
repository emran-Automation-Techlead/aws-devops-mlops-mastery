variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "app_name" {
  type    = string
  default = "box-everything"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "task_cpu" {
  description = "Fargate task vCPU units (256 = 0.25 vCPU) - each service gets its own"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Baseline task count per service before auto-scaling kicks in"
  type        = number
  default     = 1
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 4
}

locals {
  tags = {
    Project     = var.app_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  services = ["user-service", "product-service", "order-service"]
}
