resource "aws_security_group" "alb" {
  name_prefix = "${var.app_name}-alb-"
  description = "Allow inbound HTTP from the internet"
  vpc_id      = data.aws_vpc.default.id

  ingress {
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

resource "aws_security_group" "tasks" {
  name_prefix = "${var.app_name}-tasks-"
  description = "Allow container traffic from the ALB only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App port, ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    # Fargate tasks need outbound access to pull images from ECR and ship
    # logs to CloudWatch - both go over the public internet from the
    # default VPC's public subnets since there's no VPC endpoint here.
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
