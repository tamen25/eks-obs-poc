variable "namespace" {
  description = "Namespace Loki runs in. It must already exist (the root module's namespaces module creates it)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for AWS resource names (buckets, KMS alias, IAM role)."
  type        = string
}

variable "cluster" {
  description = "The EKS cluster Loki runs in, for the IAM trust policy."
  type = object({
    name              = string
    arn               = string
    oidc_provider_arn = string
    oidc_issuer_url   = string
  })
}

variable "identity" {
  description = "How Loki gets AWS credentials (irsa or pod_identity) and an optional permissions boundary."
  type = object({
    mode                     = string
    permissions_boundary_arn = optional(string)
  })
}

variable "tags" {
  description = "Tags added to every AWS resource."
  type        = map(string)
  default     = {}
}

variable "chart" {
  description = "Chart source and version."
  type = object({
    repository = string
    version    = string
  })
}

variable "settings" {
  description = "Loki settings, as defined by the root module's `loki` variable."
  type = object({
    deployment_mode      = string
    monolithic_replicas  = number
    distributed_replicas = any
    zone_aware_ingesters = bool
    tenant_id            = string
    credentials_revision = number
    schema_from          = string
    retention_period     = string
    limits               = any
    persistence_size     = string
    resources            = any
    component_resources  = any
    caches               = any
    node_selector        = map(string)
    tolerations          = list(map(string))
    gateway              = any
    service_monitor      = bool
    image_tag            = string
    extra_values_yaml    = string
  })
}

variable "storage" {
  description = "Where logs live: on Loki's volume, or in S3 with a KMS key and storage tiers (see the root module's `loki.storage`)."
  type = object({
    backend = string
    kms = object({
      create                  = bool
      key_arn                 = optional(string)
      deletion_window_in_days = number
    })
    versioning                         = bool
    noncurrent_version_expiration_days = number
    expiration_backstop_days           = optional(number)
    force_destroy                      = bool
    access_log_bucket                  = optional(string)
    allowed_vpc_endpoint_ids           = list(string)
    admin_principal_arns               = list(string)
    s3_endpoint                        = string
    tiering = object({
      enabled               = bool
      hot_days              = number
      warm_storage_class    = string
      min_object_size_bytes = number
      archive = object({
        enabled       = bool
        storage_class = string
        after_days    = number
      })
    })
  })
}

variable "storage_class" {
  description = "StorageClass for Loki volumes. Empty string uses the cluster default."
  type        = string
}

variable "image_registry" {
  description = "Registry mirror for all chart images. Empty string keeps the chart defaults."
  type        = string
}

variable "tls" {
  description = "Serve the gateway over TLS with a certificate from a CA this module creates."
  type = object({
    enabled               = bool
    server_validity_hours = number
    early_renewal_hours   = number
  })
}

variable "network_policy" {
  description = <<-EOT
    Ingress NetworkPolicies for Loki's pods. They select Loki's pods only, so they work whether
    or not other components share the namespace. clients may reach the gateway port; when the
    gateway is exposed through a load balancer, vpc_cidr_blocks may too (the load balancer's
    addresses come from the VPC).
  EOT
  type = object({
    enabled = bool
    clients = list(object({
      namespace  = string
      pod_labels = optional(map(string), {})
    }))
    monitoring_namespaces     = list(string)
    extra_ingress_cidr_blocks = list(string)
    vpc_cidr_blocks           = list(string)
  })
}
