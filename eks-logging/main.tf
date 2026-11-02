############################################################################################
# Namespaces and storage class
############################################################################################

module "namespaces" {
  source = "./modules/namespaces"

  namespaces    = { for name, level in local.namespaces : name => { name = name, pod_security = level } }
  storage_class = var.storage_class
  labels        = { "app.kubernetes.io/part-of" = "logging" }
}

############################################################################################
# Loki: storage (a volume, or S3 with an IAM role), gateway TLS, Helm release, NetworkPolicies
############################################################################################

module "loki" {
  source = "./modules/loki"
  count  = var.loki.enabled ? 1 : 0

  namespace   = var.loki.namespace
  name_prefix = local.name_prefix
  cluster     = local.cluster
  identity    = local.identity
  tags        = local.tags

  chart = {
    repository = var.loki.chart_repository
    version    = var.loki.chart_version
  }
  settings = {
    deployment_mode      = var.loki.deployment_mode
    monolithic_replicas  = coalesce(var.loki.monolithic_replicas, local.loki_sizing.replicas)
    distributed_replicas = var.loki.distributed_replicas
    zone_aware_ingesters = var.loki.zone_aware_ingesters
    tenant_id            = local.tenant_id
    credentials_revision = var.loki.credentials_revision
    schema_from          = var.loki.schema_from
    retention_period     = coalesce(var.loki.retention_period, local.loki_sizing.retention_period)
    limits               = var.loki.limits
    persistence_size     = coalesce(var.loki.persistence_size, local.loki_sizing.persistence_size)
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
  storage        = var.loki.storage
  storage_class  = var.storage_class.name
  image_registry = var.image_registry_mirror
  tls            = var.internal_tls

  network_policy = {
    enabled                   = var.network_policies.enabled
    clients                   = local.loki_clients
    monitoring_namespaces     = var.network_policies.monitoring_namespaces
    extra_ingress_cidr_blocks = var.network_policies.extra_loki_cidr_blocks
    vpc_cidr_blocks           = local.vpc_cidr_blocks
  }

  depends_on = [module.namespaces]
}

############################################################################################
# Fluent Bit: agents, event collector, optional aggregator and log-keeper, NetworkPolicies
############################################################################################

module "fluent_bit" {
  source = "./modules/fluent-bit"
  count  = var.fluent_bit.enabled ? 1 : 0

  namespace    = var.fluent_bit.namespace
  cluster_name = var.cluster_name
  chart = {
    repository = var.fluent_bit.chart_repository
    version    = var.fluent_bit.chart_version
  }
  image = var.fluent_bit.image

  loki          = local.loki_endpoint
  loki_password = local.loki_password

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
  aggregator     = var.fluent_bit.aggregator
  log_keeper     = var.fluent_bit.log_keeper
  node_logs      = var.fluent_bit.node_logs
  events_enabled = var.fluent_bit.events_enabled
  storage_class  = var.storage_class.name
  tls = {
    server_validity_hours = var.internal_tls.server_validity_hours
    early_renewal_hours   = var.internal_tls.early_renewal_hours
  }
  network_policy = {
    enabled               = var.network_policies.enabled
    monitoring_namespaces = var.network_policies.monitoring_namespaces
  }

  # The agents' readiness depends on pushing successfully, so Loki has to answer first.
  depends_on = [module.namespaces, module.loki]
}

module "pod_lifecycle" {
  source = "./modules/pod-lifecycle"
  count  = var.fluent_bit.enabled && var.pod_lifecycle.enabled ? 1 : 0

  namespace              = var.fluent_bit.namespace
  image                  = var.pod_lifecycle.image
  resources              = var.pod_lifecycle.resources
  network_policy_enabled = var.network_policies.enabled

  depends_on = [module.namespaces]
}

############################################################################################
# Grafana (optional)
############################################################################################

module "grafana" {
  source = "./modules/grafana"
  count  = var.grafana.enabled ? 1 : 0

  namespace   = var.grafana.namespace
  name_prefix = local.name_prefix
  cluster     = local.cluster
  identity    = local.identity
  aws_region  = var.aws_region
  tags        = local.tags

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
    cloudwatch_audit  = var.grafana.cloudwatch_audit
    extra_values_yaml = var.grafana.extra_values_yaml
  }
  image_registry = var.image_registry_mirror
  storage_class  = var.storage_class.name

  loki = {
    url         = local.grafana_uses_own_loki ? one(module.loki[*].gateway.url) : var.grafana.loki_datasource_url
    user        = local.grafana_uses_own_loki ? local.tenant_id : coalesce(try(var.fluent_bit.loki_endpoint.username, null), local.tenant_id)
    internal_ca = local.grafana_uses_own_loki && var.internal_tls.enabled
    ca_cert_pem = local.grafana_uses_own_loki ? one(module.loki[*].ca_cert_pem) : ""
  }
  loki_password    = local.grafana_uses_own_loki ? one(module.loki[*].tenant_password) : var.external_loki_password
  agents_namespace = var.fluent_bit.namespace

  network_policy = {
    enabled               = var.network_policies.enabled
    ingress_namespaces    = var.network_policies.grafana_ingress_namespaces
    ingress_cidr_blocks   = var.network_policies.grafana_ingress_cidr_blocks
    monitoring_namespaces = var.network_policies.monitoring_namespaces
    vpc_cidr_blocks       = local.vpc_cidr_blocks
  }

  depends_on = [module.namespaces, module.loki]
}

############################################################################################
# Plan-time warnings
############################################################################################

# NetworkPolicies are inert unless the VPC CNI enforces them. Reading the add-on fails when
# vpc-cni is self-managed; inside a check block that is a warning, not an error.
check "vpc_cni_enforces_network_policies" {
  data "aws_eks_addon" "vpc_cni" {
    cluster_name = var.cluster_name
    addon_name   = "vpc-cni"
  }

  assert {
    condition     = !var.network_policies.enabled || try(jsondecode(data.aws_eks_addon.vpc_cni.configuration_values).enableNetworkPolicy, "false") == "true"
    error_message = "The vpc-cni add-on does not have enableNetworkPolicy = \"true\", so the NetworkPolicies this stack creates are not enforced. Enable it in the add-on configuration (outside this stack)."
  }
}
