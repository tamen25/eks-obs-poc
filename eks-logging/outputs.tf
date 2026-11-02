output "loki" {
  description = "Loki endpoints and storage, or null when Loki is disabled. Buckets, KMS key, role and tiers are null with filesystem storage."
  value = var.loki.enabled ? {
    gateway_url   = module.loki[0].gateway.url
    external_url  = local.loki_external_url
    tenant        = module.loki[0].tenant_id
    buckets       = module.loki[0].bucket_names
    kms_key_arn   = module.loki[0].kms_key_arn
    role_arn      = module.loki[0].role_arn
    storage_tiers = module.loki[0].storage_tiers
  } : null
}

output "loki_tenant_password" {
  description = "Basic Auth password for the tenant. Read with: terraform output -raw loki_tenant_password"
  value       = one(module.loki[*].tenant_password)
  sensitive   = true
}

output "loki_ca_cert_pem" {
  description = "CA certificate for the Loki gateway's TLS. Empty when internal TLS is off or Loki is disabled."
  value       = var.loki.enabled ? module.loki[0].ca_cert_pem : ""
}

output "fluent_bit" {
  description = "Where the agents read and send logs, or null when collection is disabled."
  value = var.fluent_bit.enabled ? {
    namespace          = var.fluent_bit.namespace
    source_mode        = module.fluent_bit[0].source_mode
    pushes_to          = "${local.loki_endpoint.tls ? "https" : "http"}://${local.loki_endpoint.host}:${local.loki_endpoint.port}${local.loki_endpoint.uri}"
    aggregator_address = module.fluent_bit[0].aggregator_address
  } : null
}

output "grafana" {
  description = "In-cluster Grafana service and admin Secret, or null when Grafana is disabled."
  value = var.grafana.enabled ? {
    service      = module.grafana[0].service
    admin_secret = module.grafana[0].admin_secret
  } : null
}

output "amazon_managed_grafana" {
  description = <<-EOT
    Inputs for integrations/amazon-managed-grafana, or null until the gateway is exposed
    (loki.gateway.ingress or a LoadBalancer service). The password is the
    loki_tenant_password output; the CA is loki_ca_cert_pem when needs_ca_cert is true.
  EOT
  value = var.loki.enabled && local.loki_external_url != null ? {
    loki_url        = local.loki_external_url
    basic_auth_user = local.tenant_id
    needs_ca_cert   = local.loki_external_needs_ca
  } : null
}
