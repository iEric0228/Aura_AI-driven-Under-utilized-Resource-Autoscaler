variable "cluster_role_name" {
  description = "The name of the IAM role for EKS cluster"
  type        = string
}

variable "node_role_name" {
  description = "The name of the IAM role for EKS nodes"
  type        = string
}

variable "assume_role_policy" {
  description = "The assume role policy document for IAM roles"
  type        = string
}

