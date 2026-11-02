variables {
  deployment_mode     = "Monolithic"
  monolithic_replicas = 3
  distributed_replicas = {
    distributor     = 3, ingester = 3, querier = 3, query_frontend = 2
    query_scheduler = 2, index_gateway = 2, compactor = 1, ruler = 1
  }
  zone_aware_ingesters        = false
  tenant_id                   = "test-cluster"
  tenant_password_bcrypt      = "$2a$10$abcdefghijklmnopqrstuuDummyHashForTestsOnly000000000"
  storage_backend             = "s3"
  bucket_names                = { chunks = "c-bucket", ruler = "r-bucket" }
  region                      = "us-east-1"
  s3_endpoint                 = ""
  service_account_name        = "loki"
  service_account_annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/loki" }
  schema_from                 = "2025-01-01"
  retention_period            = "2160h"
  max_query_lookback          = "2160h"
  deletion_mode               = "filter-and-delete"
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
    service  = { type = "ClusterIP", annotations = {} }
    ingress  = { enabled = false, class_name = "alb", host = "", annotations = {}, tls_secret = "" }
  }
  service_monitor   = false
  image_registry    = ""
  image_tag         = ""
  extra_values_yaml = ""
}

run "monolithic_defaults" {
  command = plan

  assert {
    condition     = yamldecode(output.values[0]).deploymentMode == "Monolithic" && yamldecode(output.values[0]).singleBinary.replicas == 3
    error_message = "Monolithic mode runs the single binary with the requested replicas."
  }

  assert {
    condition     = yamldecode(output.values[0]).loki.commonConfig.replication_factor == 3
    error_message = "Replication factor follows the replica count, capped at 3."
  }

  assert {
    condition     = yamldecode(output.values[0]).loki.auth_enabled && yamldecode(output.values[0]).loki.tenants[0].name == "test-cluster"
    error_message = "Multi-tenancy must be on, with the tenant mapped from the gateway user."
  }

  assert {
    condition     = !strcontains(output.values[0], "password:") && strcontains(output.values[0], "passwordHash")
    error_message = "Only the bcrypt hash may appear in Helm values, never a plain password."
  }

  assert {
    condition     = yamldecode(output.values[0]).loki.limits_config.max_line_size_truncate
    error_message = "Over-long lines must be truncated, not silently dropped."
  }

  assert {
    condition     = yamldecode(output.values[0]).gateway.nginxConfig.ssl && yamldecode(output.values[0]).gateway.readinessProbe.httpGet.scheme == "HTTPS"
    error_message = "With TLS on, nginx listens with ssl and the probe uses HTTPS."
  }

  assert {
    condition     = yamldecode(output.values[0]).gateway.nginxConfig.clientMaxBodySize == "16M"
    error_message = "The gateway body limit must be raised above the chart's 4M."
  }

  assert {
    condition     = !yamldecode(output.values[0]).test.enabled && !yamldecode(output.values[0]).lokiCanary.enabled
    error_message = "The helm test pod (latest tag) and the canary stay off."
  }

  assert {
    condition     = output.gateway_service.port == 8080 && output.gateway_service.scheme == "https" && yamldecode(output.values[0]).gateway.service.port == 8080
    error_message = "The gateway Service port must equal the container port (8080) for VPC CNI network policies, with TLS on."
  }
}

# A schema or compactor still pointing at S3 would make Loki look for a bucket that is not there.
run "filesystem_storage_uses_no_bucket" {
  command = plan

  variables {
    storage_backend             = "filesystem"
    monolithic_replicas         = 1
    bucket_names                = { chunks = "", ruler = "" }
    region                      = ""
    service_account_annotations = {}
  }

  assert {
    condition = (
      yamldecode(output.values[0]).loki.storage == { type = "filesystem" } &&
      yamldecode(output.values[0]).loki.schemaConfig.configs[0].object_store == "filesystem" &&
      yamldecode(output.values[0]).loki.compactor.delete_request_store == "filesystem"
    )
    error_message = "Storage, schema and compactor must all use the filesystem."
  }

  assert {
    condition     = yamldecode(output.values[0]).singleBinary.replicas == 1 && yamldecode(output.values[0]).loki.commonConfig.replication_factor == 1
    error_message = "One volume means one replica, with a replication factor it can satisfy."
  }

  assert {
    condition     = yamldecode(output.values[0]).singleBinary.persistence.enabled
    error_message = "Without a volume, every log would be lost when the pod restarts."
  }
}

run "single_replica_lowers_replication_factor" {
  command = plan

  variables {
    monolithic_replicas = 1
  }

  assert {
    condition     = yamldecode(output.values[0]).loki.commonConfig.replication_factor == 1
    error_message = "One replica cannot satisfy replication factor 3."
  }
}

run "distributed_mode" {
  command = plan

  variables {
    deployment_mode      = "Distributed"
    zone_aware_ingesters = true
  }

  assert {
    condition = (
      yamldecode(output.values[0]).singleBinary.replicas == 0 &&
      yamldecode(output.values[0]).ingester.replicas == 3 &&
      yamldecode(output.values[0]).querier.replicas == 3 &&
      yamldecode(output.values[0]).ingester.zoneAwareReplication.enabled
    )
    error_message = "Distributed mode scales the components and stops the single binary."
  }
}

run "plain_http_gateway" {
  command = plan

  variables {
    gateway = {
      replicas = 1, client_max_body_size = "16M", tls_enabled = false, tls_secret_name = ""
      service  = { type = "ClusterIP", annotations = {} }
      ingress  = { enabled = false, class_name = "", host = "", annotations = {}, tls_secret = "" }
    }
  }

  assert {
    condition     = !yamldecode(output.values[0]).gateway.nginxConfig.ssl && length(yamldecode(output.values[0]).gateway.extraVolumes) == 0
    error_message = "Without TLS there is no ssl listener and no certificate volume."
  }
}

run "archived_chunks_are_never_queried" {
  command = plan

  variables {
    retention_period   = "8760h"
    max_query_lookback = "4296h"
    deletion_mode      = "filter-only"
  }

  # Queries past the archive boundary would hit objects Loki cannot read; delete requests that
  # rewrite chunks would fail on them too.
  assert {
    condition = (
      yamldecode(output.values[0]).loki.limits_config.retention_period == "8760h" &&
      yamldecode(output.values[0]).loki.limits_config.max_query_lookback == "4296h" &&
      yamldecode(output.values[0]).loki.limits_config.deletion_mode == "filter-only"
    )
    error_message = "Lookback and deletion mode must follow the inputs, independently of retention."
  }
}

run "internal_load_balancer_service" {
  command = plan

  variables {
    gateway = {
      replicas = 2, client_max_body_size = "16M", tls_enabled = true, tls_secret_name = "loki-gateway-tls"
      service = {
        type        = "LoadBalancer"
        annotations = { "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internal" }
      }
      ingress = { enabled = false, class_name = "alb", host = "", annotations = {}, tls_secret = "" }
    }
  }

  assert {
    condition = (
      yamldecode(output.values[0]).gateway.service.type == "LoadBalancer" &&
      yamldecode(output.values[0]).gateway.service.annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"] == "internal"
    )
    error_message = "The gateway Service type and annotations come from the inputs."
  }
}
