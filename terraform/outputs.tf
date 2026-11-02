output "loki_gateway_url" {
  description = "In-cluster Loki URL (push: <url>/loki/api/v1/push, query: <url>/loki/api/v1/query_range)."
  value       = module.loki.gateway.url
}

output "loki_tenant" {
  description = "Loki tenant ID, which is also the Basic Auth username."
  value       = module.loki.tenant_id
}

output "loki_tenant_password" {
  description = "Basic Auth password for the tenant. Read with: terraform output -raw loki_tenant_password"
  value       = module.loki.tenant_password
  sensitive   = true
}

output "internal_ca_cert_pem" {
  description = "CA certificate for verifying the Loki gateway (and aggregator) TLS certificates. Empty when internal TLS is off."
  value       = local.ca_cert_pem
}

output "loki_buckets" {
  description = "S3 buckets holding Loki chunks and rules."
  value       = module.loki_storage.bucket_names
}

output "loki_kms_key_arn" {
  description = "KMS key encrypting the Loki buckets."
  value       = module.loki_storage.kms_key_arn
}

output "loki_role_arn" {
  description = "IAM role Loki uses for S3."
  value       = module.loki_identity.role_arn
}

output "grafana" {
  description = "Grafana service address and admin Secret, or null when Grafana is disabled."
  value = var.grafana.enabled ? {
    service      = module.grafana[0].service
    admin_secret = module.grafana[0].admin_secret
  } : null
}

output "aggregator_address" {
  description = "Aggregator address agents forward to, or null when disabled."
  value       = module.fluent_bit.aggregator_address
}
