output "grafana" {
  description = "How to open Grafana."
  value       = "kubectl --context ${var.kube_context} -n observability port-forward svc/grafana 23030:80, then http://127.0.0.1:23030 (no login)"
}

output "grafana_admin_password" {
  description = "Grafana admin password, for the API (the UI needs no login)."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "loki_tenant" {
  description = "Loki tenant, also the Basic Auth user at the gateway."
  value       = var.tenant
}

output "loki_tenant_password" {
  description = "Basic Auth password of the Loki tenant (user = var.tenant)."
  value       = random_password.tenant.result
  sensitive   = true
}
