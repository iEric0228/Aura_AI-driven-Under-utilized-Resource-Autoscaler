terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote backend for CI/CD state persistence (S3 + DynamoDB locking).
  # Partial config: bucket and dynamodb_table are supplied at init time via
  # -backend-config so the account-specific bucket name isn't hardcoded and the
  # repo is portable across AWS accounts. scripts/bootstrap-backend.sh creates
  # these resources and prints the exact `terraform init` command to use.
  backend "s3" {
    key     = "dev/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
}

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

locals {
  account_id            = data.aws_caller_identity.current.account_id
  caller_arn            = data.aws_caller_identity.current.arn
  caller_is_assumedrole = can(regex("^arn:aws:sts::[0-9]+:assumed-role/", local.caller_arn))
  caller_role_name      = local.caller_is_assumedrole ? element(split("/", local.caller_arn), 1) : null
  caller_iam_role_arn   = local.caller_is_assumedrole ? "arn:aws:iam::${local.account_id}:role/${local.caller_role_name}" : local.caller_arn

  cluster_name      = var.cluster_name
  node_role_name    = "${var.cluster_name}-node-role"
  cluster_role_name = "${var.cluster_name}-cluster-role"
}

module "vpc" {
  source             = "../../modules/VPC"
  name               = local.cluster_name
  cidr_block         = "10.0.0.0/16"
  public_subnets     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets    = ["10.0.16.0/20", "10.0.32.0/20", "10.0.48.0/20"]
  availability_zones = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  enable_ha_nat      = var.enable_ha_nat
  tags               = { Environment = var.environment }
}

module "iam_eks" {
  source             = "../../modules/IAM_EKS"
  cluster_role_name  = local.cluster_role_name
  node_role_name     = local.node_role_name
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role_policy.json
}

module "eks" {
  source                       = "../../modules/EKS"
  cluster_name                 = local.cluster_name
  kubernetes_version           = var.kubernetes_version
  cluster_role_arn             = module.iam_eks.cluster_role_arn
  cluster_role_name            = local.cluster_role_name
  node_role_arn                = module.iam_eks.node_role_arn
  node_role_name               = local.node_role_name
  admin_principal_arn          = local.caller_iam_role_arn
  local_admin_principal_arn    = "arn:aws:iam::${local.account_id}:user/${var.local_admin_username}"
  subnet_ids                   = module.vpc.private_subnet_ids
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  cluster_log_types            = var.cluster_log_types
  node_group_desired_size      = 2
  node_group_min_size          = 2
  node_group_max_size          = 4
  node_instance_types          = ["t3.medium"]
  depends_on                   = [module.iam_eks]
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

locals {
  karpenter_controller_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DeleteLaunchTemplate",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "eks:DescribeCluster",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = module.iam_eks.node_role_arn
      }
    ]
  })
}

module "iam" {
  source                           = "../../modules/IAM"
  karpenter_controller_role_name   = "${local.cluster_name}-karpenter-controller-role"
  oidc_provider_arn                = aws_iam_openid_connect_provider.this.arn
  oidc_provider_url                = aws_iam_openid_connect_provider.this.url
  karpenter_controller_policy_json = local.karpenter_controller_policy
}
