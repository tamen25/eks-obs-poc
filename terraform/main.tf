############################################################################################
# Namespaces and storage class
############################################################################################

module "platform" {
  source = "./modules/platform"

  namespaces = {
    loki    = { name = var.namespaces.loki, pod_security = "restricted" }
    agents  = { name = var.namespaces.agents, pod_security = "privileged" }
    grafana = { name = var.namespaces.grafana, pod_security = "restricted" }
  }
  storage_class = var.storage_class
  labels        = { "app.kubernetes.io/part-of" = "logging" }
}

############################################################################################
# Loki object storage and the role that reaches it
############################################################################################

module "loki_storage" {
  source = "./modules/loki-storage"

  name_prefix                        = local.name_prefix
  kms                                = var.kms
  versioning                         = var.loki_storage.versioning
  noncurrent_version_expiration_days = var.loki_storage.noncurrent_version_expiration_days
  expiration_backstop_days           = local.expiration_backstop_days
  force_destroy                      = var.loki_storage.force_destroy
  access_log_bucket                  = var.loki_storage.access_log_bucket
  allowed_vpc_endpoint_ids           = var.loki_storage.allowed_vpc_endpoint_ids
  admin_principal_arns               = var.loki_storage.admin_principal_arns
  tags                               = local.tags
}

module "loki_identity" {
  source = "./modules/workload-identity"

  name                     = "${local.name_prefix}-loki"
  cluster_name             = var.cluster_name
  cluster_arn              = data.aws_eks_cluster.this.arn
  mode                     = var.aws_identity_mode
  oidc_provider_arn        = local.oidc_provider_arn
  oidc_issuer_url          = local.oidc_issuer_url
  namespace                = var.namespaces.loki
  service_account          = local.loki_service_account
  permissions_boundary_arn = var.iam_permissions_boundary_arn
  tags                     = local.tags

  # Read/write chunks and rules, nothing else. KMS use only through S3 in this region.
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListLokiBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = values(module.loki_storage.bucket_arns)
      },
      {
        Sid      = "ReadWriteLokiObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for arn in values(module.loki_storage.bucket_arns) : "${arn}/*"]
      },
      {
        Sid      = "UseBucketKeyViaS3"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [module.loki_storage.kms_key_arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${var.aws_region}.amazonaws.com" }
        }
      },
    ]
  })
}

############################################################################################
# Internal TLS
############################################################################################

module "internal_tls" {
  source = "./modules/internal-tls"
  count  = var.internal_tls.enabled ? 1 : 0

  common_name           = "${var.cluster_name} logging internal CA"
  server_validity_hours = var.internal_tls.server_validity_hours
  early_renewal_hours   = var.internal_tls.early_renewal_hours
  servers = merge(
    { gateway = { dns_names = local.gateway_dns_names } },
    var.aggregator.enabled ? { aggregator = { dns_names = local.aggregator_dns_names } } : {},
  )
}

locals {
  ca_cert_pem = var.internal_tls.enabled ? module.internal_tls[0].ca_cert_pem : ""
}

############################################################################################
# Loki
############################################################################################

module "loki" {
  source = "./modules/loki"

  namespace = module.platform.namespaces["loki"]
  chart = {
    repository = var.loki.chart_repository
    version    = var.loki.chart_version
  }
  settings = {
    deployment_mode      = var.loki.deployment_mode
    monolithic_replicas  = var.loki.monolithic_replicas
    distributed_replicas = var.loki.distributed_replicas
    zone_aware_ingesters = var.loki.zone_aware_ingesters
    tenant_id            = local.tenant_id
    schema_from          = var.loki.schema_from
    retention_period     = var.loki.retention_period
    limits               = var.loki.limits
    persistence_size     = var.loki.persistence_size
    resources            = var.loki.resources
    component_resources  = var.loki.component_resources
    caches               = var.loki.caches
    node_selector        = var.loki.node_selector
    tolerations          = var.loki.tolerations
    gateway              = var.loki.gateway
    service_monitor      = var.loki.service_monitor
    image_tag            = var.loki.image_tag
    extra_values_yaml    = var.loki.extra_values_yaml
  }
  storage = {
    bucket_names = module.loki_storage.bucket_names
    region       = module.loki_storage.region
    endpoint     = var.loki_storage.s3_endpoint
  }
  service_account_name        = local.loki_service_account
  service_account_annotations = module.loki_identity.service_account_annotations
  storage_class               = local.storage_class_name
  image_registry              = var.image_registry_mirror
  tls_enabled                 = var.internal_tls.enabled
  tls_material = var.internal_tls.enabled ? {
    cert_pem        = module.internal_tls[0].servers["gateway"].cert_pem
    private_key_pem = module.internal_tls[0].servers["gateway"].private_key_pem
    } : {
    cert_pem        = ""
    private_key_pem = ""
  }
  credentials_revision = var.loki.credentials_revision
  network_policy = {
    enabled = var.network_policies.enabled
    client_namespaces = concat(
      [var.namespaces.agents],
      var.grafana.enabled ? [var.namespaces.grafana] : [],
      var.network_policies.extra_client_namespaces,
    )
    monitoring_namespaces     = var.network_policies.monitoring_namespaces
    extra_ingress_cidr_blocks = var.network_policies.extra_ingress_cidr_blocks
    node_cidr_blocks          = var.network_policies.node_cidr_blocks
  }

  depends_on = [module.platform, module.loki_identity]
}

############################################################################################
# Collection
############################################################################################

module "log_keeper" {
  source = "./modules/log-keeper"
  count  = var.log_keeper.enabled ? 1 : 0

  namespace     = module.platform.namespaces["agents"]
  image         = var.log_keeper.image
  ttl_minutes   = var.log_keeper.ttl_minutes
  max_orphan_mb = var.log_keeper.max_orphan_mb
  resources     = var.log_keeper.resources
}

module "fluent_bit" {
  source = "./modules/fluent-bit"

  namespace    = module.platform.namespaces["agents"]
  cluster_name = var.cluster_name
  chart = {
    repository = var.fluent_bit.chart_repository
    version    = var.fluent_bit.chart_version
  }
  image       = var.fluent_bit.image
  source_mode = var.log_keeper.enabled ? "keep" : "containers"

  loki = {
    host        = local.loki_endpoint.host
    port        = local.loki_endpoint.port
    uri         = local.loki_endpoint.uri
    tls         = local.loki_endpoint.tls
    tls_verify  = local.loki_endpoint.tls_verify
    tenant_id   = local.loki_endpoint.tenant_id
    username    = local.loki_endpoint.username
    internal_ca = local.loki_endpoint.internal_ca
  }
  loki_password = local.loki_password
  ca_cert_pem   = local.ca_cert_pem

  tuning = {
    flush              = var.fluent_bit.flush
    refresh_interval   = var.fluent_bit.refresh_interval
    rotate_wait        = var.fluent_bit.rotate_wait
    mem_buf_limit      = var.fluent_bit.mem_buf_limit
    kube_buffer_size   = var.fluent_bit.kube_buffer_size
    log_level          = var.fluent_bit.log_level
    exclude_namespaces = var.fluent_bit.exclude_namespaces
    extra_labels       = var.fluent_bit.extra_labels
    output_workers     = var.fluent_bit.output_workers
    agent_resources    = var.fluent_bit.agent_resources
    events_resources   = var.fluent_bit.events_resources
    selinux_type       = var.fluent_bit.selinux_type
    service_monitor    = var.fluent_bit.service_monitor
  }

  aggregator = {
    enabled      = var.aggregator.enabled
    replicas     = var.aggregator.replicas
    storage_size = var.aggregator.storage_size
    resources    = var.aggregator.resources
  }
  aggregator_tls = var.aggregator.enabled && var.internal_tls.enabled ? {
    cert_pem        = module.internal_tls[0].servers["aggregator"].cert_pem
    private_key_pem = module.internal_tls[0].servers["aggregator"].private_key_pem
    } : {
    cert_pem        = ""
    private_key_pem = ""
  }
  storage_class  = local.storage_class_name
  events_enabled = var.fluent_bit.events_enabled

  depends_on = [module.loki, module.log_keeper]
}

module "network_policies" {
  source = "./modules/network-policies"
  count  = var.network_policies.enabled ? 1 : 0

  agents_namespace            = module.platform.namespaces["agents"]
  grafana_namespace           = var.grafana.enabled ? module.platform.namespaces["grafana"] : ""
  aggregator_enabled          = var.aggregator.enabled
  monitoring_namespaces       = var.network_policies.monitoring_namespaces
  node_cidr_blocks            = var.network_policies.node_cidr_blocks
  grafana_ingress_namespaces  = var.network_policies.grafana_ingress_namespaces
  grafana_ingress_cidr_blocks = var.network_policies.grafana_ingress_cidr_blocks
}

module "pod_lifecycle" {
  source = "./modules/pod-lifecycle"
  count  = var.pod_lifecycle.enabled ? 1 : 0

  namespace = module.platform.namespaces["agents"]
  image     = var.pod_lifecycle.image
  resources = var.pod_lifecycle.resources
}

############################################################################################
# Grafana
############################################################################################

module "grafana_identity" {
  source = "./modules/workload-identity"
  count  = var.grafana.enabled && var.grafana.cloudwatch_audit ? 1 : 0

  name                     = "${local.name_prefix}-grafana-cw"
  cluster_name             = var.cluster_name
  cluster_arn              = data.aws_eks_cluster.this.arn
  mode                     = var.aws_identity_mode
  oidc_provider_arn        = local.oidc_provider_arn
  oidc_issuer_url          = local.oidc_issuer_url
  namespace                = var.namespaces.grafana
  service_account          = "grafana"
  permissions_boundary_arn = var.iam_permissions_boundary_arn
  tags                     = local.tags

  # Read the cluster's control plane log group only.
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "QueryClusterAuditLog"
        Effect = "Allow"
        Action = [
          "logs:StartQuery",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = [local.audit_log_group_arn, "${local.audit_log_group_arn}:*"]
      },
      {
        Sid      = "QueryResultsAndDiscovery"
        Effect   = "Allow"
        Action   = ["logs:GetQueryResults", "logs:StopQuery", "logs:DescribeLogGroups", "logs:GetLogGroupFields"]
        Resource = "*"
      },
    ]
  })
}

module "grafana" {
  source = "./modules/grafana"
  count  = var.grafana.enabled ? 1 : 0

  namespace = module.platform.namespaces["grafana"]
  chart = {
    repository = var.grafana.chart_repository
    version    = var.grafana.chart_version
  }
  settings = {
    replicas          = var.grafana.replicas
    image_tag         = var.grafana.image_tag
    persistence_size  = var.grafana.persistence_size
    ingress           = var.grafana.ingress
    root_url          = var.grafana.root_url
    ini_overrides     = var.grafana.ini_overrides
    resources         = var.grafana.resources
    node_selector     = var.grafana.node_selector
    tolerations       = var.grafana.tolerations
    extra_values_yaml = var.grafana.extra_values_yaml
  }
  image_registry = var.image_registry_mirror
  storage_class  = local.storage_class_name

  loki = {
    url  = var.grafana.loki_datasource_url != "" ? var.grafana.loki_datasource_url : module.loki.gateway.url
    user = module.loki.tenant_id
  }
  loki_password = module.loki.tenant_password
  # The internal CA only applies when the datasource points at this stack's gateway.
  loki_tls    = var.internal_tls.enabled && var.grafana.loki_datasource_url == ""
  ca_cert_pem = local.ca_cert_pem

  cloudwatch = {
    enabled                     = var.grafana.cloudwatch_audit
    region                      = var.aws_region
    audit_log_group_arn         = local.audit_log_group_arn
    audit_log_group_name        = local.audit_log_group_name
    service_account_annotations = var.grafana.cloudwatch_audit ? module.grafana_identity[0].service_account_annotations : {}
  }
  agents_namespace = var.namespaces.agents

  depends_on = [module.loki]
}
