# Pure module: turns typed inputs into the Helm values for grafana-community/loki.
# No providers, so tests/render can produce the YAML offline and `helm template` can check
# it against the chart's strict JSON schema.

variable "deployment_mode" {
  type = string
}

variable "monolithic_replicas" {
  type = number
}

variable "distributed_replicas" {
  type = object({
    distributor     = number
    ingester        = number
    querier         = number
    query_frontend  = number
    query_scheduler = number
    index_gateway   = number
    compactor       = number
    ruler           = number
  })
}

variable "zone_aware_ingesters" {
  type = bool
}

variable "tenant_id" {
  type = string
}

variable "tenant_password_bcrypt" {
  type      = string
  sensitive = true
}

# "filesystem" or "s3". With filesystem, bucket_names, region and s3_endpoint are not used.
variable "storage_backend" {
  type = string
}

variable "bucket_names" {
  type = object({
    chunks = string
    ruler  = string
  })
}

variable "region" {
  type = string
}

variable "s3_endpoint" {
  type = string
}

variable "service_account_name" {
  type = string
}

variable "service_account_annotations" {
  type = map(string)
}

variable "schema_from" {
  type = string
}

variable "retention_period" {
  type = string
}

# How far back queries may reach. Shorter than retention_period when old chunks sit in an
# archive storage class that Loki cannot read without a restore.
variable "max_query_lookback" {
  type = string
}

# "filter-and-delete" rewrites chunks to honour delete requests; "filter-only" hides the lines
# at query time instead, which is the only mode that works when chunks may be archived.
variable "deletion_mode" {
  type = string
}

variable "limits" {
  type = object({
    ingestion_rate_mb           = number
    ingestion_burst_size_mb     = number
    per_stream_rate_limit       = string
    per_stream_rate_limit_burst = string
    max_line_size               = string
    max_line_size_truncate      = bool
    max_global_streams_per_user = number
    max_query_series            = number
    query_timeout               = string
  })
}

variable "persistence" {
  type = object({
    size          = string
    storage_class = string
  })
}

variable "resources" {
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_memory   = string
  })
}

variable "component_resources" {
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_memory   = string
  })
}

variable "caches" {
  type = object({
    chunks_enabled    = bool
    chunks_memory_mb  = number
    results_enabled   = bool
    results_memory_mb = number
  })
}

variable "node_selector" {
  type = map(string)
}

variable "tolerations" {
  type = list(map(string))
}

variable "gateway" {
  type = object({
    replicas             = number
    client_max_body_size = string
    tls_enabled          = bool
    tls_secret_name      = string
    service = object({
      type        = string
      annotations = map(string)
    })
    ingress = object({
      enabled     = bool
      class_name  = string
      host        = string
      annotations = map(string)
      tls_secret  = string
    })
  })
}

variable "service_monitor" {
  type = bool
}

variable "image_registry" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "extra_values_yaml" {
  type = string
}
