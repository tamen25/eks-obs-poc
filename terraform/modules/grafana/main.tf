locals {
  admin_secret    = "grafana-admin"
  loki_secret     = "grafana-loki-credentials"
  ca_secret       = "grafana-loki-ca"
  dashboards_name = "grafana-logging-dashboards"
  tls_to_loki     = var.loki_tls

  evicted_pods_dashboard = replace(
    file("${path.module}/dashboards/evicted-pods.json"),
    "__AGENTS_NAMESPACE__", var.agents_namespace,
  )

  audit_dashboard = replace(replace(
    file("${path.module}/dashboards/eks-eviction-audit.json"),
    "__AUDIT_LOG_GROUP_ARN__", var.cloudwatch.audit_log_group_arn),
    "__AUDIT_LOG_GROUP_NAME__", var.cloudwatch.audit_log_group_name,
  )
}

# Initial admin login. Wire SSO through settings.ini_overrides (auth.generic_oauth and
# friends) and keep this account for break-glass use.
resource "random_password" "admin" {
  length  = 32
  special = false

  keepers = {
    revision = var.admin_credentials_revision
  }
}

resource "kubernetes_secret_v1" "admin" {
  metadata {
    name      = local.admin_secret
    namespace = var.namespace
  }

  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.admin.result
  }
}

resource "kubernetes_secret_v1" "loki" {
  metadata {
    name      = local.loki_secret
    namespace = var.namespace
  }

  data = {
    password = var.loki_password
  }
}

resource "kubernetes_secret_v1" "ca" {
  count = local.tls_to_loki ? 1 : 0

  metadata {
    name      = local.ca_secret
    namespace = var.namespace
  }

  data = {
    "ca.crt" = var.ca_cert_pem
  }
}

resource "kubernetes_config_map_v1" "dashboards" {
  metadata {
    name      = local.dashboards_name
    namespace = var.namespace
  }

  data = merge(
    { "evicted-pods.json" = local.evicted_pods_dashboard },
    var.cloudwatch.enabled ? { "eks-eviction-audit.json" = local.audit_dashboard } : {},
  )
}

module "values" {
  source = "./values"

  replicas       = var.settings.replicas
  image_registry = var.image_registry
  image_tag      = var.settings.image_tag
  admin_secret   = local.admin_secret
  persistence = {
    enabled       = var.settings.replicas == 1
    size          = var.settings.persistence_size
    storage_class = var.storage_class
  }
  ingress       = var.settings.ingress
  root_url      = var.settings.root_url
  ini_overrides = var.settings.ini_overrides
  loki_datasource = {
    url             = var.loki.url
    user            = var.loki.user
    password_secret = local.loki_secret
    tls_ca_secret   = local.tls_to_loki ? local.ca_secret : ""
  }
  cloudwatch = {
    enabled = var.cloudwatch.enabled
    region  = var.cloudwatch.region
  }
  service_account_annotations = var.cloudwatch.service_account_annotations
  dashboards_config_map       = local.dashboards_name
  resources                   = var.settings.resources
  node_selector               = var.settings.node_selector
  tolerations                 = var.settings.tolerations
  extra_values_yaml           = var.settings.extra_values_yaml
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = "grafana"
  version    = var.chart.version

  values = module.values.values

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600
  max_history     = 10

  depends_on = [
    kubernetes_secret_v1.admin,
    kubernetes_secret_v1.loki,
    kubernetes_secret_v1.ca,
    kubernetes_config_map_v1.dashboards,
  ]
}
