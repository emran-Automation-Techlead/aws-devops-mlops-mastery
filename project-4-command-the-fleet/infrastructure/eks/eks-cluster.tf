# Using the community terraform-aws-modules/eks module rather than
# hand-writing every aws_eks_cluster/aws_iam_role/OIDC provider resource.
# This is the realistic professional choice, not a shortcut: EKS's IAM
# trust policies (especially for IRSA - IAM Roles for Service Accounts,
# used throughout this project) are notoriously easy to get subtly wrong
# by hand, and this module is what most real-world Terraform EKS setups
# actually use. Pin the version; check the module's CHANGELOG before
# bumping major versions - its interface does change between them.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # worker nodes live in private subnets

  cluster_endpoint_public_access = true # simplest for a learning cluster; a real prod setup would restrict this to a VPN/bastion CIDR

  # IRSA (IAM Roles for Service Accounts) lets a specific Kubernetes
  # ServiceAccount assume a specific IAM role - so the AWS Load Balancer
  # Controller, Cluster Autoscaler, and External Secrets Operator each
  # get ONLY the AWS permissions they individually need, instead of
  # every pod on every node sharing one broad node IAM role.
  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      labels = {
        role = "general"
      }
    }
  }

  # Lets the Cluster Autoscaler find and manage this node group's ASG.
  node_security_group_tags = {
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
  }

  # EKS Access Entries - the modern replacement for hand-editing the
  # aws-auth ConfigMap. This is what actually populates the "developers"
  # Kubernetes group that k8s/manifests/rbac/developer-rolebinding.yaml
  # binds permissions to: anyone who assumes developer_iam_role_arn shows
  # up inside the cluster as a member of the "developers" k8s group,
  # automatically, with zero manual kubectl commands.
  access_entries = var.developer_iam_role_arn != "" ? {
    developers = {
      principal_arn     = var.developer_iam_role_arn
      type              = "STANDARD"
      kubernetes_groups = ["developers"]
    }
  } : {}

  tags = local.tags
}
