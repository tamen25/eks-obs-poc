data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# The cluster's VPC, so NetworkPolicies can admit load balancers without hand-entered CIDRs.
data "aws_vpc" "cluster" {
  id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
}

locals {
  name_prefix = coalesce(var.name_prefix, "${substr(var.cluster_name, 0, 24)}-logs")
  tenant_id   = coalesce(var.loki.tenant_id, var.cluster_name)

  # Filesystem storage keeps every log on one volume, so it needs a bigger volume and shorter
  # retention than S3. With 90 days on 50Gi, 50 GB/day of raw logs would fill it in about a week.
  loki_sizing = {
    filesystem = { replicas = 1, retention_period = "168h", persistence_size = "100Gi" }
    s3         = { replicas = 3, retention_period = "2160h", persistence_size = "50Gi" }
  }[var.loki.storage.backend]

  tags = merge(var.tags, {
    "environment"         = var.environment
    "eks-cluster"         = var.cluster_name
    "managed-by"          = "terraform"
    "terraform-stack"     = "eks-logging"
    "data-classification" = "logs"
  })

  oidc_issuer_url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  cluster = {
    name              = var.cluster_name
    arn               = data.aws_eks_cluster.this.arn
    oidc_issuer_url   = local.oidc_issuer_url
    oidc_provider_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(local.oidc_issuer_url, "https://", "")}"
  }
  identity = {
    mode                     = var.aws_identity_mode
    permissions_boundary_arn = var.iam_permissions_boundary_arn
  }

  vpc_cidr_blocks = [for a in data.aws_vpc.cluster.cidr_block_associations : a.cidr_block]

  # Namespaces follow the components. A namespace that hosts the node agents must allow
  # hostPath ("privileged"); merge() lets that win when Loki or Grafana share it.
  namespaces = merge(
    var.loki.enabled ? { (var.loki.namespace) = "restricted" } : {},
    var.grafana.enabled ? { (var.grafana.namespace) = "restricted" } : {},
    var.fluent_bit.enabled ? { (var.fluent_bit.namespace) = "privileged" } : {},
  )

  # Who may call the Loki gateway. Pod labels are the charts' fixed labels; the Fluent Bit
  # entry covers the agent and the event collector.
  loki_clients = concat(
    var.fluent_bit.enabled ? [
      { namespace = var.fluent_bit.namespace, pod_labels = { "app.kubernetes.io/name" = "fluent-bit" } },
      { namespace = var.fluent_bit.namespace, pod_labels = { "app.kubernetes.io/name" = "fluent-bit-aggregator" } },
    ] : [],
    var.grafana.enabled ? [
      { namespace = var.grafana.namespace, pod_labels = { "app.kubernetes.io/name" = "grafana" } },
    ] : [],
    [for ns in var.network_policies.extra_loki_client_namespaces : { namespace = ns, pod_labels = tomap({}) }],
  )

  # Where the agents push: this stack's gateway, or fluent_bit.loki_endpoint.
  loki_endpoint = var.fluent_bit.loki_endpoint == null ? {
    host        = one(module.loki[*].gateway.host)
    port        = one(module.loki[*].gateway.port)
    uri         = "/loki/api/v1/push"
    tls         = var.internal_tls.enabled
    tls_verify  = true
    tenant_id   = ""
    username    = local.tenant_id
    internal_ca = var.internal_tls.enabled
    ca_cert_pem = one(module.loki[*].ca_cert_pem)
    } : {
    host        = var.fluent_bit.loki_endpoint.host
    port        = var.fluent_bit.loki_endpoint.port
    uri         = var.fluent_bit.loki_endpoint.uri
    tls         = var.fluent_bit.loki_endpoint.tls
    tls_verify  = var.fluent_bit.loki_endpoint.tls_verify
    tenant_id   = var.fluent_bit.loki_endpoint.tenant_id
    username    = var.fluent_bit.loki_endpoint.username
    internal_ca = var.fluent_bit.loki_endpoint.ca_cert_pem != ""
    ca_cert_pem = var.fluent_bit.loki_endpoint.ca_cert_pem
  }
  loki_password = var.fluent_bit.loki_endpoint == null ? one(module.loki[*].tenant_password) : var.external_loki_password

  # Grafana's datasource: this stack's gateway unless grafana.loki_datasource_url is set.
  grafana_uses_own_loki = var.loki.enabled && var.grafana.loki_datasource_url == ""

  # How a client outside the cluster (Amazon Managed Grafana) reaches the gateway, if exposed.
  # The ALB terminates TLS with an ACM certificate; the NLB passes through to the gateway's
  # own certificate, so clients need the internal CA.
  loki_external_url = (
    var.loki.gateway.ingress.enabled ? "https://${var.loki.gateway.ingress.host}" :
    var.loki.gateway.service.type == "LoadBalancer" && length(var.loki.gateway.extra_dns_names) > 0 ?
    "${var.internal_tls.enabled ? "https" : "http"}://${var.loki.gateway.extra_dns_names[0]}:8080" : null
  )
  loki_external_needs_ca = !var.loki.gateway.ingress.enabled && var.loki.gateway.service.type == "LoadBalancer" && var.internal_tls.enabled
}
