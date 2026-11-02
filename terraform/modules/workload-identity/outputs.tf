output "role_arn" {
  description = "ARN of the workload role."
  value       = aws_iam_role.this.arn
}

output "service_account_annotations" {
  description = "Annotations the service account needs: the IRSA role annotation, or none for Pod Identity."
  value       = var.mode == "irsa" ? { "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn } : {}
}
