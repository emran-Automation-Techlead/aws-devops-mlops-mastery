# Projects 1-3 deliberately used the default VPC to avoid NAT Gateway
# costs, since none of them needed worker nodes hidden from the public
# internet. This is where that tradeoff flips: EKS worker nodes are
# standard practice to run in PRIVATE subnets (no direct inbound path
# from the internet at all, only outbound through NAT for image pulls
# etc.) - the security benefit is worth the ~$32/month NAT Gateway cost
# once you're running an actual cluster, not just a couple of Fargate
# tasks.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT, not one-per-AZ - real HA setups use one per AZ, this is the cost-conscious teaching version
  enable_dns_hostnames = true

  # EKS auto-discovers subnets for load balancer placement using these
  # exact tags - the AWS Load Balancer Controller reads them to know
  # "public subnets get internet-facing ALBs, private subnets get
  # internal ones." Miss these and Ingress creation fails silently.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = local.tags
}
