output "cluster_name" {
  value = module.eks.cluster_name
}
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "karpenter_controller_role_arn" {
  value = module.iam.karpenter_controller_role_arn
}

output "karpenter_controller_policy_arn" {
  value = module.iam.karpenter_controller_policy_arn
}

output "node_instance_profile_name" {
  value = module.iam_eks.node_instance_profile_name
}