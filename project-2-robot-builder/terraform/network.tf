# Deliberately using the account's default VPC instead of provisioning a
# new one. A custom VPC would need NAT Gateways to let private-subnet
# instances reach the internet for package installs (~$32/month each,
# per AZ) - real money for zero teaching value at this stage. Project 4's
# EKS cluster is where a purpose-built VPC actually earns its complexity.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
