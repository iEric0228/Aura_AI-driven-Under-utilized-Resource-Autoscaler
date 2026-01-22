resource "aws_iam_role" "karpenter_controller" {
  name = var.karpenter_controller_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(var.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller_policy" {
  count      = var.karpenter_controller_policy_arn == null ? 0 : 1
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = var.karpenter_controller_policy_arn
}

resource "aws_iam_policy" "karpenter_controller_inline" {
  name   = "${var.karpenter_controller_role_name}-policy"
  policy = var.karpenter_controller_policy_json
}

resource "aws_iam_role_policy_attachment" "karpenter_controller_inline_attachment" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller_inline.arn
}

output "karpenter_controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}

output "karpenter_controller_policy_arn" {
  value = aws_iam_policy.karpenter_controller_inline.arn
}