resource "aws_iam_role" "eks_cluster_role" {
  name               = var.cluster_role_name
  assume_role_policy = var.assume_role_policy
}

resource "aws_iam_role" "eks_node_role" {
  name               = var.node_role_name
  assume_role_policy = var.assume_role_policy
}

resource "aws_iam_instance_profile" "eks_node_instance_profile" {
  name = "${var.node_role_name}-instance-profile"
  role = aws_iam_role.eks_node_role.name
}

output "cluster_role_arn" {
  value = aws_iam_role.eks_cluster_role.arn
}

output "node_role_arn" {
  value = aws_iam_role.eks_node_role.arn
}

output "node_instance_profile_name" {
  value = aws_iam_instance_profile.eks_node_instance_profile.name
}
