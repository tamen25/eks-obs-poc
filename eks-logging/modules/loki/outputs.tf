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

output "tls_enabled" {
  description = "Whether the gateway serves TLS (known at plan time, unlike the CA PEM)."
  value       = var.tls.enabled
}

output "ca_cert_pem" {
  description = "CA certificate that signed the gateway certificate. Empty when TLS is off."
  value       = var.tls.enabled ? module.tls[0].ca_cert_pem : ""
}

output "bucket_names" {
  description = "S3 buckets holding chunks and rules. Null with filesystem storage."
  value       = one(module.storage[*].bucket_names)
}

output "kms_key_arn" {
  description = "KMS key encrypting the buckets. Null with filesystem storage."
  value       = one(module.storage[*].kms_key_arn)
}

output "role_arn" {
  description = "IAM role Loki uses for S3. Null with filesystem storage."
  value       = one(module.identity[*].role_arn)
}

output "storage_tiers" {
  description = "Chunk storage classes by age, and how far back queries reach."
  value = merge(try(module.storage[0].chunk_tiers, {}), {
    query_lookback   = local.max_query_lookback
    retention_period = var.settings.retention_period
    deletion_mode    = local.deletion_mode
  })
}

output "values" {
  description = "Rendered Helm values (for review and tests)."
  value       = module.values.values
  sensitive   = true
}

output "network_policy" {
  description = "What the NetworkPolicies admit to the gateway (for review and tests)."
  value = {
    default_deny        = length(kubernetes_network_policy_v1.default_deny_ingress) == 1
    client_namespaces   = distinct([for c in var.network_policy.clients : c.namespace])
    gateway_cidr_blocks = local.gateway_cidr_blocks
  }
}
