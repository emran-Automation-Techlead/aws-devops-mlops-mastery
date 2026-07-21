output "data_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "models_bucket" {
  value = aws_s3_bucket.models.bucket
}

output "sagemaker_execution_role_arn" {
  value = aws_iam_role.sagemaker_execution.arn
}

output "model_package_group_name" {
  value = aws_sagemaker_model_package_group.fraud_detection.model_package_group_name
}

output "feature_group_name" {
  value = aws_sagemaker_feature_group.transactions.feature_group_name
}

output "ecr_model_server_repository_url" {
  value = aws_ecr_repository.model_server.repository_url
}

output "glue_job_name" {
  value = aws_glue_job.feature_engineering.name
}

output "glue_database_name" {
  value = aws_glue_catalog_database.fraud_detection.name
}

output "prediction_log_table" {
  value = aws_dynamodb_table.prediction_log.name
}

output "drift_alerts_topic_arn" {
  value = aws_sns_topic.drift_alerts.arn
}

output "retraining_state_machine_arn" {
  value = aws_sfn_state_machine.retraining.arn
}

output "model_server_irsa_role_arn" {
  value = module.model_server_irsa.iam_role_arn
}

output "mlflow_ingress_hostname" {
  description = "Once the ALB provisions (a few minutes after apply), MLFLOW_TRACKING_URI = http://<this>"
  value       = try(kubernetes_ingress_v1.mlflow.status[0].load_balancer[0].ingress[0].hostname, "not yet provisioned - check `kubectl get ingress -n mlflow`")
}
