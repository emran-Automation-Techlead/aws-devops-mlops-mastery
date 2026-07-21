variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "teach-the-machine"
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster from Project 4 - this project deploys into it rather than creating its own"
  type        = string
  default     = "command-the-fleet"
}

variable "psi_drift_threshold" {
  description = "PSI above which drift_detector.py alerts and triggers retraining"
  type        = number
  default     = 0.25
}

variable "drift_check_schedule" {
  description = "EventBridge schedule expression for the drift-detection Lambda"
  type        = string
  default     = "rate(6 hours)"
}

variable "alert_email" {
  type    = string
  default = ""
}

locals {
  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}
