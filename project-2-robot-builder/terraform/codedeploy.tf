resource "aws_codedeploy_app" "app" {
  name             = var.app_name
  compute_platform = "Server"
  tags             = local.tags
}

# Blue/green with an Auto Scaling Group: CodeDeploy provisions a whole
# NEW copy of the ASG (the "green" fleet), waits for it to pass health
# checks on the green target group, shifts the ALB listener over, then
# terminates the old "blue" instances. Visitors never see a half-deployed
# instance - the switch is atomic at the listener level.
resource "aws_codedeploy_deployment_group" "app" {
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = "${var.app_name}-deployment-group"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.AllAtOnce"

  autoscaling_groups = [aws_autoscaling_group.app.name]

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.app.arn]
      }
      target_group {
        name = aws_lb_target_group.blue.name
      }
      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }

  # This is how CodeDeploy finds the green fleet's instances to run
  # lifecycle hooks on - it just needs a tag they all share.
  ec2_tag_set {
    ec2_tag_filter {
      key   = "Name"
      type  = "KEY_AND_VALUE"
      value = var.app_name
    }
  }

  # This is the actual mechanism behind "push bad code -> deployment
  # blocked": if ValidateService (or any hook) fails, CodeDeploy stops
  # and reverts - the green fleet never receives traffic.
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}
