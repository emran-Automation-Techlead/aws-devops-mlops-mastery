resource "aws_security_group" "alb" {
  name_prefix = "${var.app_name}-alb-"
  description = "Allow inbound HTTP from the internet to the load balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.app_name}-app-"
  description = "Allow app traffic from the ALB only - no direct internet access, no SSH port"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App port, ALB only"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# No SSH ingress rule exists anywhere in this file, on purpose. When you
# need to get onto an instance, use AWS Systems Manager Session Manager
# (IAM-authenticated, every command audit-logged, no open port 22, no key
# pair to lose): `aws ssm start-session --target <instance-id>`
