output "admin_secret" {
  description = "Namespace/name of the Secret holding the Grafana admin login."
  value       = "${var.namespace}/${local.admin_secret}"
}

output "service" {
  description = "In-cluster Grafana address."
  value       = "http://grafana.${var.namespace}.svc.cluster.local"
}

output "values" {
  description = "Rendered Helm values (for review and tests)."
  value       = module.values.values
}
