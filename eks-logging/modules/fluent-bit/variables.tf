variable "namespace" {
  description = "Namespace for the agents, event collector, aggregator and log-keeper. It must already exist and allow privileged pods (hostPath)."
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
    condition     = var.image.tag != "" && var.image.tag != "latest"
    error_message = "image.tag must be a pinned version."
  }
}

variable "loki" {
  description = "Loki push endpoint, the user to push as, and how to verify its certificate."
  type = object({
    host       = string
    port       = number
    uri        = string
    tls        = bool
    tls_verify = bool
    tenant_id  = string
    username   = string
    # true: verify against ca_cert_pem (a private CA). false: the system CA bundle.
    # Kept separate from the PEM, which is often only known after apply.
    internal_ca = bool
    ca_cert_pem = string
  })
}

variable "loki_password" {
  description = "Password for the Loki endpoint."
  type        = string
  sensitive   = true
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
  description = "Optional aggregator tier (see the root module's fluent_bit.aggregator)."
  type = object({
    enabled      = bool
    replicas     = number
    storage_size = string
    resources    = any
  })
}

variable "node_logs" {
  description = "journald collection on every node (see the root module's fluent_bit.node_logs)."
  type = object({
    enabled      = bool
    journal_path = string
    units        = list(string)
    kernel       = bool
  })
}

variable "log_keeper" {
  description = "Optional log-keeper DaemonSet (see the root module's fluent_bit.log_keeper)."
  type = object({
    enabled       = bool
    image         = string
    ttl_minutes   = number
    max_orphan_mb = number
    resources = object({
      requests = map(string)
      limits   = map(string)
    })
  })

  validation {
    condition = !var.log_keeper.enabled || (
      can(regex("^[^\\s@]+[:@][^\\s]+$", var.log_keeper.image)) && !endswith(var.log_keeper.image, ":latest")
    )
    error_message = "log_keeper.image must be an image reference with a pinned tag or digest (not :latest)."
  }
}

variable "tls" {
  description = "Validity of the aggregator's server certificate."
  type = object({
    server_validity_hours = number
    early_renewal_hours   = number
  })
}

variable "storage_class" {
  description = "StorageClass for aggregator volumes. Empty string uses the cluster default."
  type        = string
}

variable "events_enabled" {
  description = "Run the Kubernetes event collector (Evicted, Preempting, Killing, NodeNotReady events)."
  type        = bool
}

variable "network_policy" {
  description = "Ingress NetworkPolicies for this module's pods (they select its pods only)."
  type = object({
    enabled               = bool
    monitoring_namespaces = list(string)
  })
}
