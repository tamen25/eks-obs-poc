locals {
  tls_secret_name = "loki-gateway-tls"
}

# One credential per tenant: the gateway maps the Basic Auth user to the tenant ID.
# The plain password reaches clients through Kubernetes Secrets; Loki only ever sees the
# bcrypt hash, which random_password computes once and keeps stable in state.
resource "random_password" "tenant" {
  length  = 40
  special = false

  keepers = {
    revision = var.credentials_revision
  }
}

resource "kubernetes_secret_v1" "gateway_tls" {
  count = var.tls_enabled ? 1 : 0

  metadata {
    name      = local.tls_secret_name
    namespace = var.namespace
  }

  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = var.tls_material.cert_pem
    "tls.key" = var.tls_material.private_key_pem
  }
}

module "values" {
  source = "./values"

  deployment_mode             = var.settings.deployment_mode
  monolithic_replicas         = var.settings.monolithic_replicas
  distributed_replicas        = var.settings.distributed_replicas
  zone_aware_ingesters        = var.settings.zone_aware_ingesters
  tenant_id                   = var.settings.tenant_id
  tenant_password_bcrypt      = random_password.tenant.bcrypt_hash
  bucket_names                = var.storage.bucket_names
  region                      = var.storage.region
  s3_endpoint                 = var.storage.endpoint
  service_account_name        = var.service_account_name
  service_account_annotations = var.service_account_annotations
  schema_from                 = var.settings.schema_from
  retention_period            = var.settings.retention_period
  limits                      = var.settings.limits
  persistence                 = { size = var.settings.persistence_size, storage_class = var.storage_class }
  resources                   = var.settings.resources
  component_resources         = var.settings.component_resources
  caches                      = var.settings.caches
  node_selector               = var.settings.node_selector
  tolerations                 = var.settings.tolerations
  gateway = merge(var.settings.gateway, {
    tls_enabled     = var.tls_enabled
    tls_secret_name = local.tls_secret_name
  })
  service_monitor   = var.settings.service_monitor
  image_registry    = var.image_registry
  image_tag         = var.settings.image_tag
  extra_values_yaml = var.settings.extra_values_yaml
}

resource "helm_release" "loki" {
  name       = "loki"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = "loki"
  version    = var.chart.version

  values = module.values.values

  # Roll back a failed upgrade instead of leaving a half-applied release, and wait for the
  # StatefulSets so later modules start against a Loki that answers.
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900
  max_history     = 10

  depends_on = [kubernetes_secret_v1.gateway_tls]
}
