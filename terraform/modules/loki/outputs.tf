output "gateway" {
  description = "In-cluster address of the Loki gateway."
  value = {
    host   = "${module.values.gateway_service.name}.${var.namespace}.svc.cluster.local"
    port   = module.values.gateway_service.port
    scheme = module.values.gateway_service.scheme
    url    = "${module.values.gateway_service.scheme}://${module.values.gateway_service.name}.${var.namespace}.svc.cluster.local:${module.values.gateway_service.port}"
  }
}

output "tenant_id" {
  description = "Tenant ID, which is also the Basic Auth username."
  value       = var.settings.tenant_id
}

output "tenant_password" {
  description = "Basic Auth password for the tenant."
  value       = random_password.tenant.result
  sensitive   = true
}

output "values" {
  description = "Rendered Helm values (for review and tests)."
  value       = module.values.values
  sensitive   = true
}
