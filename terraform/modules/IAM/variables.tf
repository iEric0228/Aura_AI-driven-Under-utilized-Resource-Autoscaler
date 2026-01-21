variable "role_name" {
  description = "The name of the IAM role for EKS cluster"
  type        = string
}

variable "assume_role_policy" {
  description = "The assume role policy document for IAM roles"
  type        = string
}

variable "policy_arn" {
  description = "The ARN of the IAM policy to attach"
  type        = string
}

variable "karpenter_controller_role_name" {
  description = "The name of the Karpenter controller IAM role"
  type        = string
}

variable "oidc_provider_arn" {
  description = "The ARN of the OIDC provider for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "The URL of the OIDC provider for IRSA"
  type        = string
}

variable "karpenter_controller_policy_arn" {
  description = "The ARN of the Karpenter controller policy"
  type        = string
}

