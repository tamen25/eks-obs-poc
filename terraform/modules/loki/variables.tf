variable "namespace" {
  description = "Namespace Loki runs in (created by the platform module)."
  type        = string
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
  description = "Object storage Loki writes to."
  type = object({
    bucket_names = object({ chunks = string, ruler = string })
    region       = string
    endpoint     = string
  })
}

variable "service_account_name" {
  description = "Service account Loki pods run as; the IAM role is bound to it."
  type        = string
}

variable "service_account_annotations" {
  description = "Annotations for the service account (the IRSA role ARN, or none for Pod Identity)."
  type        = map(string)
}

variable "storage_class" {
  description = "StorageClass for Loki volumes. Empty string uses the cluster default."
  type        = string
}

variable "image_registry" {
  description = "Registry mirror for all chart images. Empty string keeps the chart defaults."
  type        = string
}

variable "tls_enabled" {
  description = "Serve the gateway over TLS with the certificate in tls_material."
  type        = bool
}

variable "tls_material" {
  description = "Gateway certificate and key (PEM). Ignored when tls_enabled is false."
  type = object({
    cert_pem        = string
    private_key_pem = string
  })
  sensitive = true
}

variable "network_policy" {
  description = <<-EOT
    NetworkPolicies for the Loki namespace. Only takes effect if the cluster enforces them
    (VPC CNI with network policy enabled, Calico, Cilium).
  EOT
  type = object({
    enabled                   = bool
    client_namespaces         = list(string)
    monitoring_namespaces     = list(string)
    extra_ingress_cidr_blocks = list(string)
    node_cidr_blocks          = list(string)
  })
}

variable "credentials_revision" {
  description = "Change this to generate a new tenant password (rotation)."
  type        = number
  default     = 1
}
