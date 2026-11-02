data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = coalesce(var.name_prefix, "${substr(var.cluster_name, 0, 24)}-logs")
  tenant_id   = coalesce(var.loki.tenant_id, var.cluster_name)

  tags = merge(var.tags, {
    "environment"         = var.environment
    "eks-cluster"         = var.cluster_name
    "managed-by"          = "terraform"
    "terraform-stack"     = "eks-logging"
    "data-classification" = "logs"
  })

  oidc_issuer_url   = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_provider_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(local.oidc_issuer_url, "https://", "")}"

  # Retention backstop: S3 deletes objects a month after Loki should have.
  retention_days           = tonumber(trimsuffix(var.loki.retention_period, "h")) / 24
  expiration_backstop_days = coalesce(var.loki_storage.expiration_backstop_days, ceil(local.retention_days) + 30)

  loki_service_account = "loki"

  # Internal endpoints for TLS certificates.
  gateway_dns_names = [
    "loki-gateway.${var.namespaces.loki}.svc.cluster.local",
    "loki-gateway.${var.namespaces.loki}.svc",
    "loki-gateway.${var.namespaces.loki}",
  ]
  aggregator_dns_names = [
    "fluent-bit-aggregator.${var.namespaces.agents}.svc.cluster.local",
    "fluent-bit-aggregator.${var.namespaces.agents}.svc",
  ]

  # Where the agents push: this stack's gateway, or the override.
  own_loki_endpoint = {
    host        = module.loki.gateway.host
    port        = module.loki.gateway.port
    uri         = "/loki/api/v1/push"
    tls         = var.internal_tls.enabled
    tls_verify  = true
    tenant_id   = ""
    username    = module.loki.tenant_id
    internal_ca = var.internal_tls.enabled
  }
  # An override endpoint is verified against the system CA bundle, not the internal CA.
  loki_endpoint = var.fluent_bit.loki_endpoint_override == null ? local.own_loki_endpoint : merge(
    var.fluent_bit.loki_endpoint_override, { internal_ca = false },
  )
  loki_password = var.fluent_bit.loki_endpoint_override == null ? module.loki.tenant_password : var.loki_endpoint_password

  storage_class_name = var.storage_class.name

  audit_log_group_name = "/aws/eks/${var.cluster_name}/cluster"
  audit_log_group_arn  = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.audit_log_group_name}"
}
