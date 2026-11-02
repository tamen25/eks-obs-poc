locals {
  credentials_secret = "loki-credentials"
  ca_secret          = "logging-internal-ca"
  forward_key_secret = "fluent-bit-forward-key"
  ca_mount_path      = "/fluent-bit/tls-ca"
  aggregator_name    = "fluent-bit-aggregator"
  aggregator_port    = 24224
  needs_ca           = var.loki.internal_ca || var.aggregator.enabled
}

module "values" {
  source = "./values"

  source_mode    = var.source_mode
  via_aggregator = var.aggregator.enabled
  loki = {
    host        = var.loki.host
    port        = var.loki.port
    uri         = var.loki.uri
    tls         = var.loki.tls
    tls_verify  = var.loki.tls_verify
    tenant_id   = var.loki.tenant_id
    internal_ca = var.loki.internal_ca
  }
  ca_mount_path = local.ca_mount_path
  aggregator = {
    host = "${local.aggregator_name}.${var.namespace}.svc.cluster.local"
    port = local.aggregator_port
  }
  tuning = {
    flush              = var.tuning.flush
    refresh_interval   = var.tuning.refresh_interval
    rotate_wait        = var.tuning.rotate_wait
    mem_buf_limit      = var.tuning.mem_buf_limit
    kube_buffer_size   = var.tuning.kube_buffer_size
    log_level          = var.tuning.log_level
    exclude_namespaces = var.tuning.exclude_namespaces
    static_labels      = merge(var.tuning.extra_labels, { cluster = var.cluster_name })
    output_workers     = var.tuning.output_workers
  }
  chart = {
    image_repository   = var.image.repository
    image_tag          = var.image.tag
    agent_config_map   = "fluent-bit-agent-config"
    events_config_map  = "fluent-bit-events-config"
    credentials_secret = local.credentials_secret
    ca_secret          = local.ca_secret
    forward_key_secret = local.forward_key_secret
    agent_resources    = var.tuning.agent_resources
    events_resources   = var.tuning.events_resources
    service_monitor    = var.tuning.service_monitor
    selinux_type       = var.tuning.selinux_type
  }
}

resource "kubernetes_secret_v1" "loki_credentials" {
  metadata {
    name      = local.credentials_secret
    namespace = var.namespace
  }

  data = {
    username = var.loki.username
    password = var.loki_password
  }
}

resource "kubernetes_secret_v1" "internal_ca" {
  count = local.needs_ca ? 1 : 0

  metadata {
    name      = local.ca_secret
    namespace = var.namespace
  }

  data = {
    "ca.crt" = var.ca_cert_pem
  }
}

resource "kubernetes_config_map_v1" "agent" {
  metadata {
    name      = "fluent-bit-agent-config"
    namespace = var.namespace
  }

  data = {
    "fluent-bit.yaml" = module.values.agent_config_yaml
  }
}

resource "kubernetes_config_map_v1" "events" {
  count = var.events_enabled ? 1 : 0

  metadata {
    name      = "fluent-bit-events-config"
    namespace = var.namespace
  }

  data = {
    "fluent-bit.yaml" = module.values.events_config_yaml
  }
}

resource "helm_release" "agent" {
  name       = "fluent-bit"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = "fluent-bit"
  version    = var.chart.version

  values = [module.values.agent_values_yaml]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600
  max_history     = 10

  depends_on = [
    kubernetes_config_map_v1.agent,
    kubernetes_secret_v1.loki_credentials,
    kubernetes_secret_v1.internal_ca,
    kubernetes_stateful_set_v1.aggregator,
  ]
}

resource "helm_release" "events" {
  count = var.events_enabled ? 1 : 0

  name       = "fluent-bit-events"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = "fluent-bit"
  version    = var.chart.version

  values = [module.values.events_values_yaml]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 300
  max_history     = 10

  depends_on = [
    kubernetes_config_map_v1.events,
    kubernetes_secret_v1.loki_credentials,
    kubernetes_secret_v1.internal_ca,
  ]
}
