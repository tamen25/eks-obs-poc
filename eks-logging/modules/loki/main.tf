locals {
  tls_secret_name = "loki-gateway-tls"
  service_account = "loki"

  on_s3          = var.storage.backend == "s3"
  retention_days = tonumber(trimsuffix(var.settings.retention_period, "h")) / 24
  tiering        = var.storage.tiering
  archive_on     = local.on_s3 && local.tiering.enabled && local.tiering.archive.enabled

  # Archived chunks need a restore before Loki can read them, so queries stop one day short of
  # the archive transition (S3 applies lifecycle rules once a day, not at an exact hour).
  max_query_lookback = local.archive_on ? "${(local.tiering.archive.after_days - 1) * 24}h" : var.settings.retention_period
  deletion_mode      = local.archive_on ? "filter-only" : "filter-and-delete"

  # S3 deletes anything a month after Loki should have, in case the compactor stops.
  expiration_backstop_days = coalesce(var.storage.expiration_backstop_days, ceil(local.retention_days) + 30)

  warm_days = local.archive_on ? local.tiering.archive.after_days - local.tiering.hot_days : local.retention_days - local.tiering.hot_days

  gateway_exposed = var.settings.gateway.ingress.enabled || var.settings.gateway.service.type == "LoadBalancer"
  gateway_dns_names = distinct(compact(concat(
    [
      "loki-gateway.${var.namespace}.svc.cluster.local",
      "loki-gateway.${var.namespace}.svc",
      "loki-gateway.${var.namespace}",
    ],
    var.settings.gateway.extra_dns_names,
  )))
}

############################################################################################
# Object storage and the role that reaches it
############################################################################################

module "storage" {
  source = "./storage"
  count  = local.on_s3 ? 1 : 0

  name_prefix                        = var.name_prefix
  kms                                = var.storage.kms
  versioning                         = var.storage.versioning
  noncurrent_version_expiration_days = var.storage.noncurrent_version_expiration_days
  expiration_backstop_days           = local.expiration_backstop_days
  force_destroy                      = var.storage.force_destroy
  access_log_bucket                  = var.storage.access_log_bucket
  allowed_vpc_endpoint_ids           = var.storage.allowed_vpc_endpoint_ids
  admin_principal_arns               = var.storage.admin_principal_arns
  tiering                            = merge(local.tiering, { tenants = [var.settings.tenant_id] })
  tags                               = var.tags
}

module "identity" {
  source = "../workload-identity"
  count  = local.on_s3 ? 1 : 0

  name                     = "${var.name_prefix}-loki"
  cluster_name             = var.cluster.name
  cluster_arn              = var.cluster.arn
  mode                     = var.identity.mode
  oidc_provider_arn        = var.cluster.oidc_provider_arn
  oidc_issuer_url          = var.cluster.oidc_issuer_url
  namespace                = var.namespace
  service_account          = local.service_account
  permissions_boundary_arn = var.identity.permissions_boundary_arn
  tags                     = var.tags

  # Read/write chunks and rules, nothing else. KMS use only through S3 in this region.
  # Storage class transitions are done by S3 itself and need no permission here.
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListLokiBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = values(module.storage[0].bucket_arns)
      },
      {
        Sid      = "ReadWriteLokiObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for arn in values(module.storage[0].bucket_arns) : "${arn}/*"]
      },
      {
        Sid      = "UseBucketKeyViaS3"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [module.storage[0].kms_key_arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${module.storage[0].region}.amazonaws.com" }
        }
      },
    ]
  })
}

############################################################################################
# Gateway TLS and the tenant credential
############################################################################################

module "tls" {
  source = "../internal-tls"
  count  = var.tls.enabled ? 1 : 0

  common_name           = "${var.cluster.name} Loki gateway CA"
  server_validity_hours = var.tls.server_validity_hours
  early_renewal_hours   = var.tls.early_renewal_hours
  servers               = { gateway = { dns_names = local.gateway_dns_names } }
}

# One credential per tenant: the gateway maps the Basic Auth user to the tenant ID.
# The plain password reaches clients through Kubernetes Secrets; Loki only ever sees the
# bcrypt hash, which random_password computes once and keeps stable in state.
resource "random_password" "tenant" {
  length  = 40
  special = false

  keepers = {
    revision = var.settings.credentials_revision
  }
}

resource "kubernetes_secret_v1" "gateway_tls" {
  count = var.tls.enabled ? 1 : 0

  metadata {
    name      = local.tls_secret_name
    namespace = var.namespace
  }

  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = module.tls[0].servers["gateway"].cert_pem
    "tls.key" = module.tls[0].servers["gateway"].private_key_pem
  }
}

############################################################################################
# Helm release
############################################################################################

module "values" {
  source = "./values"

  deployment_mode             = var.settings.deployment_mode
  monolithic_replicas         = var.settings.monolithic_replicas
  distributed_replicas        = var.settings.distributed_replicas
  zone_aware_ingesters        = var.settings.zone_aware_ingesters
  tenant_id                   = var.settings.tenant_id
  tenant_password_bcrypt      = random_password.tenant.bcrypt_hash
  storage_backend             = var.storage.backend
  bucket_names                = local.on_s3 ? module.storage[0].bucket_names : { chunks = "", ruler = "" }
  region                      = local.on_s3 ? module.storage[0].region : ""
  s3_endpoint                 = var.storage.s3_endpoint
  service_account_name        = local.service_account
  service_account_annotations = local.on_s3 ? module.identity[0].service_account_annotations : {}
  schema_from                 = var.settings.schema_from
  retention_period            = var.settings.retention_period
  max_query_lookback          = local.max_query_lookback
  deletion_mode               = local.deletion_mode
  limits                      = var.settings.limits
  persistence                 = { size = var.settings.persistence_size, storage_class = var.storage_class }
  resources                   = var.settings.resources
  component_resources         = var.settings.component_resources
  caches                      = var.settings.caches
  node_selector               = var.settings.node_selector
  tolerations                 = var.settings.tolerations
  gateway = {
    replicas             = var.settings.gateway.replicas
    client_max_body_size = var.settings.gateway.client_max_body_size
    tls_enabled          = var.tls.enabled
    tls_secret_name      = local.tls_secret_name
    service              = var.settings.gateway.service
    ingress              = var.settings.gateway.ingress
  }
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

  lifecycle {
    precondition {
      condition     = !local.archive_on || local.retention_days > local.tiering.archive.after_days
      error_message = "With the archive tier on, loki.retention_period must be longer than loki.storage.tiering.archive.after_days, or chunks are deleted before they are archived."
    }
  }

  depends_on = [kubernetes_secret_v1.gateway_tls, module.identity]
}

# The warm class bills a minimum duration (90 days GLACIER_IR, 30 STANDARD_IA) plus a fee per
# transitioned object. At us-east-1 prices and 1 MiB chunks, that only beats S3 Standard when
# chunks stay warm for about 45 days (GLACIER_IR) or 30 days (STANDARD_IA). README has the maths.
check "warm_tier_saves_money" {
  assert {
    condition     = !local.on_s3 || !local.tiering.enabled || local.warm_days >= (local.tiering.warm_storage_class == "GLACIER_IR" ? 45 : 30)
    error_message = "Chunks spend only ${local.warm_days} days in ${local.tiering.warm_storage_class}; with its minimum billed duration and transition fees this likely costs more than leaving them in S3 Standard. Raise loki.retention_period, lower hot_days, or turn tiering off."
  }
}

check "archive_tier_outlives_its_minimum_duration" {
  assert {
    condition     = !local.archive_on || local.retention_days - local.tiering.archive.after_days >= (local.tiering.archive.storage_class == "DEEP_ARCHIVE" ? 180 : 90)
    error_message = "Archived chunks are deleted before the ${local.tiering.archive.storage_class} minimum billed duration; S3 charges an early deletion fee."
  }
}
