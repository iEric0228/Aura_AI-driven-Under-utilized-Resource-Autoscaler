data "aws_iam_policy_document" "eks_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com", "ec2.amazonaws.com"]
    }
  }
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source             = "../../modules/VPC"
  name               = "aura-eks-dev"
  cidr_block         = "10.0.0.0/16"
  public_subnets     = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets    = ["10.0.3.0/24", "10.0.4.0/24"]
  availability_zones = ["us-east-1a", "us-east-1b"]
  tags               = { Environment = "dev" }
}

module "iam_eks" {
  source             = "../../modules/IAM_EKS"
  cluster_role_name  = "aura-eks-cluster-role"
  node_role_name     = "aura-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role_policy.json
}

module "eks" {
  source                  = "../../modules/EKS"
  cluster_name            = "aura-eks-dev"
  cluster_role_arn        = module.iam_eks.cluster_role_arn
  cluster_role_name       = "aura-eks-cluster-role"
  node_role_arn           = module.iam_eks.node_role_arn
  node_role_name          = "aura-eks-node-role"
  admin_principal_arn     = data.aws_caller_identity.current.arn
  subnet_ids              = module.vpc.private_subnet_ids
  node_group_desired_size = 1
  node_group_min_size     = 1
  node_group_max_size     = 2
  node_instance_types     = ["t3.medium"]
}

data "external" "oidc_thumbprint" {
  program = ["python3", "${path.module}/get-oidc-thumbprint.py"]
  query = {
    url = module.eks.cluster_oidc_issuer_url
  }
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.external.oidc_thumbprint.result["thumbprint"]]
  url             = module.eks.cluster_oidc_issuer_url
  depends_on      = [module.eks]
}

data "local_file" "karpenter_controller_policy" {
  filename = "${path.module}/karpenter-controller-policy.json"
}

module "iam" {
  source                           = "../../modules/IAM"
  karpenter_controller_role_name   = "aura-karpenter-controller-role"
  oidc_provider_arn                = aws_iam_openid_connect_provider.this.arn
  oidc_provider_url                = aws_iam_openid_connect_provider.this.url
  karpenter_controller_policy_json = data.local_file.karpenter_controller_policy.content
}
