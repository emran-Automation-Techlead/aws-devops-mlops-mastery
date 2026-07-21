resource "aws_ecs_cluster" "main" {
  name = var.app_name

  # Container Insights adds per-task/per-service CPU, memory, network
  # metrics to CloudWatch automatically - without it you only get
  # cluster-level aggregates, which aren't enough to tell WHICH service
  # is having a problem.
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = toset(local.services)
  name              = "/ecs/${var.app_name}-${each.value}"
  retention_in_days = 14
  tags              = local.tags
}

# Environment variables differ per service - order-service needs to know
# where to find the other two. Locally that's docker-compose DNS; here
# it's the ALB's own path-based routes (see alb.tf) - the same load
# balancer external users hit.
locals {
  service_env = {
    "user-service" = [
      { name = "REDIS_URL", value = "" }, # intentionally unset - see user-service/main.py's graceful-degradation comment
    ]
    "product-service" = []
    "order-service" = [
      { name = "USER_SERVICE_URL", value = "http://${aws_lb.app.dns_name}/users" },
      { name = "PRODUCT_SERVICE_URL", value = "http://${aws_lb.app.dns_name}/products" },
    ]
  }
}

resource "aws_ecs_task_definition" "service" {
  for_each = toset(local.services)

  family                   = "${var.app_name}-${each.value}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = local.tags

  container_definitions = jsonencode([
    {
      name      = each.value
      image     = "${aws_ecr_repository.service[each.value].repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        for e in local.service_env[each.value] : { name = e.name, value = e.value }
        if e.value != ""
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service[each.value].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = each.value
        }
      }
    }
  ])

  # Terraform manages the task definition's shape (CPU, memory, env vars,
  # log config); deploy-ecs.sh manages WHICH image tag is actually
  # running via force-new-deployment against the ":latest" tag already
  # baked in above. This split (infra vs. image) is exactly what
  # separates "terraform apply" from "day-to-day deploys" - you don't
  # re-run Terraform every time you ship a code change.
  lifecycle {
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "service" {
  for_each = toset(local.services)

  name            = "${var.app_name}-${each.value}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service[each.value].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true # no NAT Gateway - see network.tf
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service[each.value].arn
    container_name   = each.value
    container_port   = 8000
  }

  # Standard ECS rolling deployment (not blue/green like Project 2's
  # CodeDeploy setup) - ECS starts new tasks, waits for them to pass the
  # ALB health check, THEN stops old ones. Simpler than CodeDeploy
  # blue/green, still zero-downtime, just less control over the cutover.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  depends_on = [aws_lb_listener_rule.path_routing]

  tags = local.tags
}
