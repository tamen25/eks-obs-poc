# Renders the Helm values and Fluent Bit configs the stack would produce, with no cloud
# access, so scripts/validate.sh can run them through `helm template`, kubeconform and
# checkov. The inputs mirror the root module's defaults plus the optional modes.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

locals {
  out = "${path.module}/out"

  loki_common = {
    monolithic_replicas = 3
    distributed_replicas = {
      distributor     = 3, ingester = 3, querier = 3, query_frontend = 2
      query_scheduler = 2, index_gateway = 2, compactor = 1, ruler = 1
    }
    tenant_id                   = "test-cluster"
    tenant_password_bcrypt      = "$2a$10$abcdefghijklmnopqrstuuDummyHashForRenderingOnly0000"
    bucket_names                = { chunks = "test-logs-chunks-123456789012-us-east-1", ruler = "test-logs-ruler-123456789012-us-east-1" }
    region                      = "us-east-1"
    s3_endpoint                 = ""
    service_account_name        = "loki"
    service_account_annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/test-logs-loki" }
    schema_from                 = "2025-01-01"
    retention_period            = "744h"
    limits = {
      ingestion_rate_mb           = 16, ingestion_burst_size_mb = 32, per_stream_rate_limit = "5MB"
      per_stream_rate_limit_burst = "20MB", max_line_size = "256KB", max_line_size_truncate = true
      max_global_streams_per_user = 10000, max_query_series = 1000, query_timeout = "300s"
    }
    persistence         = { size = "50Gi", storage_class = "logging-gp3-encrypted" }
    resources           = { requests_cpu = "1", requests_memory = "2Gi", limits_memory = "4Gi" }
    component_resources = { requests_cpu = "250m", requests_memory = "512Mi", limits_memory = "2Gi" }
    caches              = { chunks_enabled = true, chunks_memory_mb = 2048, results_enabled = true, results_memory_mb = 512 }
    node_selector       = {}
    tolerations         = []
    gateway = {
      replicas = 2, client_max_body_size = "16M", tls_enabled = true, tls_secret_name = "loki-gateway-tls"
      ingress = {
        enabled     = true, class_name = "alb", host = "loki.internal.example.com", tls_secret = ""
        annotations = { "alb.ingress.kubernetes.io/scheme" = "internal", "alb.ingress.kubernetes.io/backend-protocol" = "HTTPS" }
      }
    }
    service_monitor   = false
    image_registry    = ""
    image_tag         = ""
    extra_values_yaml = ""
  }

  fb_common = {
    loki = {
      host = "loki-gateway.loki.svc.cluster.local", port = 443, uri = "/loki/api/v1/push"
      tls  = true, tls_verify = true, tenant_id = "", internal_ca = true
    }
    ca_mount_path = "/fluent-bit/tls-ca"
    aggregator    = { host = "fluent-bit-aggregator.logging.svc.cluster.local", port = 24224 }
    tuning = {
      flush     = 1, refresh_interval = 2, rotate_wait = 300, mem_buf_limit = "50MB", kube_buffer_size = "512k"
      log_level = "info", exclude_namespaces = [], static_labels = { cluster = "test-cluster" }, output_workers = 2
    }
    chart = {
      image_repository   = "cr.fluentbit.io/fluent/fluent-bit", image_tag = "5.1.3"
      agent_config_map   = "fluent-bit-agent-config", events_config_map = "fluent-bit-events-config"
      credentials_secret = "loki-credentials", ca_secret = "logging-internal-ca", forward_key_secret = "fluent-bit-forward-key"
      agent_resources    = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = "512Mi" } }
      events_resources   = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "256Mi" } }
      service_monitor    = false, selinux_type = ""
    }
  }
}

module "loki_monolithic" {
  source               = "../../modules/loki/values"
  deployment_mode      = "Monolithic"
  zone_aware_ingesters = false

  monolithic_replicas         = local.loki_common.monolithic_replicas
  distributed_replicas        = local.loki_common.distributed_replicas
  tenant_id                   = local.loki_common.tenant_id
  tenant_password_bcrypt      = local.loki_common.tenant_password_bcrypt
  bucket_names                = local.loki_common.bucket_names
  region                      = local.loki_common.region
  s3_endpoint                 = local.loki_common.s3_endpoint
  service_account_name        = local.loki_common.service_account_name
  service_account_annotations = local.loki_common.service_account_annotations
  schema_from                 = local.loki_common.schema_from
  retention_period            = local.loki_common.retention_period
  limits                      = local.loki_common.limits
  persistence                 = local.loki_common.persistence
  resources                   = local.loki_common.resources
  component_resources         = local.loki_common.component_resources
  caches                      = local.loki_common.caches
  node_selector               = local.loki_common.node_selector
  tolerations                 = local.loki_common.tolerations
  gateway                     = local.loki_common.gateway
  service_monitor             = local.loki_common.service_monitor
  image_registry              = local.loki_common.image_registry
  image_tag                   = local.loki_common.image_tag
  extra_values_yaml           = local.loki_common.extra_values_yaml
}

module "loki_distributed" {
  source               = "../../modules/loki/values"
  deployment_mode      = "Distributed"
  zone_aware_ingesters = true

  monolithic_replicas         = local.loki_common.monolithic_replicas
  distributed_replicas        = local.loki_common.distributed_replicas
  tenant_id                   = local.loki_common.tenant_id
  tenant_password_bcrypt      = local.loki_common.tenant_password_bcrypt
  bucket_names                = local.loki_common.bucket_names
  region                      = local.loki_common.region
  s3_endpoint                 = local.loki_common.s3_endpoint
  service_account_name        = local.loki_common.service_account_name
  service_account_annotations = local.loki_common.service_account_annotations
  schema_from                 = local.loki_common.schema_from
  retention_period            = local.loki_common.retention_period
  limits                      = local.loki_common.limits
  persistence                 = local.loki_common.persistence
  resources                   = local.loki_common.resources
  component_resources         = local.loki_common.component_resources
  caches                      = local.loki_common.caches
  node_selector               = local.loki_common.node_selector
  tolerations                 = local.loki_common.tolerations
  gateway                     = local.loki_common.gateway
  service_monitor             = local.loki_common.service_monitor
  image_registry              = local.loki_common.image_registry
  image_tag                   = local.loki_common.image_tag
  extra_values_yaml           = local.loki_common.extra_values_yaml
}

module "fluent_bit_containers" {
  source         = "../../modules/fluent-bit/values"
  source_mode    = "containers"
  via_aggregator = false
  loki           = local.fb_common.loki
  ca_mount_path  = local.fb_common.ca_mount_path
  aggregator     = local.fb_common.aggregator
  tuning         = local.fb_common.tuning
  chart          = local.fb_common.chart
}

module "fluent_bit_keep_aggregator" {
  source         = "../../modules/fluent-bit/values"
  source_mode    = "keep"
  via_aggregator = true
  loki           = local.fb_common.loki
  ca_mount_path  = local.fb_common.ca_mount_path
  aggregator     = local.fb_common.aggregator
  tuning         = local.fb_common.tuning
  chart          = local.fb_common.chart
}

module "grafana" {
  source         = "../../modules/grafana/values"
  replicas       = 1
  image_registry = ""
  image_tag      = ""
  admin_secret   = "grafana-admin"
  persistence    = { enabled = true, size = "10Gi", storage_class = "logging-gp3-encrypted" }
  ingress = {
    enabled     = true, class_name = "alb", host = "grafana.internal.example.com", tls_secret = ""
    annotations = { "alb.ingress.kubernetes.io/scheme" = "internal" }
  }
  root_url      = "https://grafana.internal.example.com"
  ini_overrides = {}
  loki_datasource = {
    url             = "https://loki-gateway.loki.svc.cluster.local:443", user = "test-cluster"
    password_secret = "grafana-loki-credentials", tls_ca_secret = "grafana-loki-ca"
  }
  cloudwatch                  = { enabled = true, region = "us-east-1" }
  service_account_annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/test-logs-grafana-cw" }
  dashboards_config_map       = "grafana-logging-dashboards"
  resources                   = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "1Gi" } }
  node_selector               = {}
  tolerations                 = []
  extra_values_yaml           = ""
}

resource "local_file" "rendered" {
  for_each = {
    "loki-monolithic.values.yaml"  = nonsensitive(module.loki_monolithic.values[0])
    "loki-distributed.values.yaml" = nonsensitive(module.loki_distributed.values[0])
    "fb-agent.values.yaml"         = module.fluent_bit_containers.agent_values_yaml
    "fb-events.values.yaml"        = module.fluent_bit_containers.events_values_yaml
    "fb-agent.config.yaml"         = module.fluent_bit_containers.agent_config_yaml
    "fb-events.config.yaml"        = module.fluent_bit_containers.events_config_yaml
    "fb-agent-keep.values.yaml"    = module.fluent_bit_keep_aggregator.agent_values_yaml
    "fb-agent-keep.config.yaml"    = module.fluent_bit_keep_aggregator.agent_config_yaml
    "fb-aggregator.config.yaml"    = module.fluent_bit_keep_aggregator.aggregator_config_yaml
    "grafana.values.yaml"          = module.grafana.values[0]
  }

  filename        = "${local.out}/${each.key}"
  content         = each.value
  file_permission = "0644"
}
