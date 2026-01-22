variable "cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
}

variable "cluster_role_arn" {
  description = "The ARN of the IAM role to associate with the EKS cluster"
  type        = string
}

variable "cluster_role_name" {
  description = "The name of the IAM role to associate with the EKS cluster (used for policy attachments)"
  type        = string
}

variable "node_role_arn" {
  description = "The ARN of the IAM role to associate with the EKS node group"
  type        = string
}

variable "node_role_name" {
  description = "The name of the IAM role to associate with the EKS node group (used for policy attachments)"
  type        = string
}

variable "subnet_ids" {
  description = "The subnet IDs to use for the EKS cluster and node group"
  type        = list(string)
}

variable "node_group_desired_size" {
  description = "The desired size of the EKS node group"
  type        = number
}

variable "node_group_max_size" {
  description = "The maximum size of the EKS node group"
  type        = number
}

variable "node_group_min_size" {
  description = "The minimum size of the EKS node group"
  type        = number
}

variable "node_instance_types" {
  description = "The instance types to use for the EKS nodes"
  type        = list(string)
}

variable "admin_principal_arn" {
  description = "IAM principal ARN to grant EKS cluster admin access (via access entry)"
  type        = string
}
