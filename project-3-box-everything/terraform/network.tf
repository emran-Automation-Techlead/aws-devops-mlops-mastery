# Same reasoning as Project 2: default VPC, no NAT Gateway. Fargate tasks
# get a public IP directly (assign_public_ip = true in ecs.tf) so they
# can reach ECR/CloudWatch over the default VPC's internet gateway
# without paying for a NAT Gateway that would otherwise cost more than
# everything else in this project combined.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
