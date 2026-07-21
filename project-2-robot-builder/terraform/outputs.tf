output "alb_dns_name" {
  description = "Public URL of the load balancer"
  value       = "http://${aws_lb.app.dns_name}"
}

output "codepipeline_name" {
  value = aws_codepipeline.app.name
}

output "codedeploy_app_name" {
  value = aws_codedeploy_app.app.name
}

output "pipeline_artifact_bucket" {
  value = aws_s3_bucket.pipeline_artifacts.bucket
}

output "github_connection_arn" {
  description = "Open this in the AWS Console (Developer Tools -> Settings -> Connections) and click Update pending connection to finish authorizing GitHub - Terraform cannot complete this step"
  value       = aws_codestarconnections_connection.github.arn
}

output "cloudwatch_alarm_name" {
  value = aws_cloudwatch_metric_alarm.error_rate.alarm_name
}
