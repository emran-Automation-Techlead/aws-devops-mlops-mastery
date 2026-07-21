# Step scaling with explicit alarms (rather than a single target-tracking
# policy like Project 2's ASG) - deliberately, to show the more granular
# technique: two independent thresholds (scale OUT above 70%, scale IN
# below 20%) instead of one target value the system tries to hover
# around. Worth knowing both; target tracking is usually the simpler
# default choice for new projects.
resource "aws_appautoscaling_target" "service" {
  for_each = toset(local.services)

  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.service[each.value].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "scale_out" {
  for_each = toset(local.services)

  name               = "${var.app_name}-${each.value}-scale-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.service[each.value].resource_id
  scalable_dimension = aws_appautoscaling_target.service[each.value].scalable_dimension
  service_namespace  = aws_appautoscaling_target.service[each.value].service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      scaling_adjustment          = 1
      metric_interval_lower_bound = 0
    }
  }
}

resource "aws_appautoscaling_policy" "scale_in" {
  for_each = toset(local.services)

  name               = "${var.app_name}-${each.value}-scale-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.service[each.value].resource_id
  scalable_dimension = aws_appautoscaling_target.service[each.value].scalable_dimension
  service_namespace  = aws_appautoscaling_target.service[each.value].service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"

    step_adjustment {
      scaling_adjustment          = -1
      metric_interval_upper_bound = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  for_each = toset(local.services)

  alarm_name          = "${var.app_name}-${each.value}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale out ${each.value} - average CPU above 70% for 2 minutes"
  alarm_actions       = [aws_appautoscaling_policy.scale_out[each.value].arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.service[each.value].name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  for_each = toset(local.services)

  alarm_name          = "${var.app_name}-${each.value}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 20
  alarm_description   = "Scale in ${each.value} - average CPU below 20% for 3 minutes"
  alarm_actions       = [aws_appautoscaling_policy.scale_in[each.value].arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.service[each.value].name
  }

  tags = local.tags
}
