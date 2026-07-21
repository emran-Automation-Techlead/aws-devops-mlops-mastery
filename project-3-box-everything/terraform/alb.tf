resource "aws_lb" "app" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
  tags               = local.tags
}

# target_type = "ip", not "instance" - Fargate tasks don't run on
# instances you manage, each task gets its own elastic network interface,
# so the ALB targets IPs directly. This is the #1 thing that trips people
# up coming from Project 2's EC2/ASG target groups.
resource "aws_lb_target_group" "service" {
  for_each = toset(local.services)

  name        = "${var.app_name}-${each.value}"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = local.tags
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  # No rule matches "/" itself - a request to the bare ALB domain gets
  # this instead of a confusing 404 from whichever service happened to be
  # the default.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "box-everything: try /users, /products, or /orders"
      status_code  = "200"
    }
  }
}

resource "aws_lb_listener_rule" "path_routing" {
  for_each     = toset(local.services)
  listener_arn = aws_lb_listener.app.arn

  # user-service -> /users*, product-service -> /products*, etc. Strips
  # "-service" and pluralizes the remainder to match each app's own
  # route prefix (/users, /products, /orders) - see each service's
  # main.py.
  priority = index(local.services, each.value) + 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.value].arn
  }

  condition {
    path_pattern {
      values = ["/${replace(each.value, "-service", "s")}*"]
    }
  }
}
