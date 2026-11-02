variable "namespace" {
  description = "Namespace for the agents, the event collector and the aggregator."
  type        = string
}

variable "cluster_name" {
  description = "Value of the cluster label on every log stream."
  type        = string
}

variable "chart" {
  description = "Fluent Bit chart source and version."
  type = object({
    repository = string
    version    = string
  })
}

variable "image" {
  description = "Fluent Bit image (repository and an explicit tag; the aggregator uses it too)."
  type = object({
    repository = string
    tag        = string
  })

  validation {
    condition     = var.image.tag != ""
    error_message = "image.tag must be set explicitly."
  }
}

variable "source_mode" {
  description = "Where the agent reads logs: \"containers\" (/var/log/containers) or \"keep\" (/var/log/keep, written by log-keeper)."
  type        = string
}

variable "loki" {
  description = "Loki push endpoint and the credentials to use."
  type = object({
    host        = string
    port        = number
    uri         = string
    tls         = bool
    tls_verify  = bool
    tenant_id   = string
    username    = string
    internal_ca = bool # verify with the internal CA (true) or the system CA bundle (false)
  })
}

variable "loki_password" {
  description = "Password for the Loki endpoint."
  type        = string
  sensitive   = true
}

variable "ca_cert_pem" {
  description = "CA certificate that signed the Loki gateway and aggregator certificates. Empty when neither uses TLS."
  type        = string
}

variable "tuning" {
  description = "Agent behaviour (see the root module's fluent_bit variable)."
  type = object({
    flush              = number
    refresh_interval   = number
    rotate_wait        = number
    mem_buf_limit      = string
    kube_buffer_size   = string
    log_level          = string
    exclude_namespaces = list(string)
    extra_labels       = map(string)
    output_workers     = number
    agent_resources    = any
    events_resources   = any
    selinux_type       = string
    service_monitor    = bool
  })
}

variable "aggregator" {
  description = "Optional aggregator tier (see the root module's aggregator variable)."
  type = object({
    enabled      = bool
    replicas     = number
    storage_size = string
    resources    = any
  })
}

variable "aggregator_tls" {
  description = "Server certificate and key (PEM) for the aggregator's forward listener."
  type = object({
    cert_pem        = string
    private_key_pem = string
  })
  sensitive = true
}

variable "storage_class" {
  description = "StorageClass for aggregator volumes. Empty string uses the cluster default."
  type        = string
}

variable "events_enabled" {
  description = "Run the Kubernetes event collector."
  type        = bool
}
