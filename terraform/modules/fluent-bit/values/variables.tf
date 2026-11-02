# Pure module: renders Fluent Bit pipeline configs (YAML format) and chart values for the
# node agent, the event collector and the optional aggregator. No providers.

variable "source_mode" {
  type = string # "containers" or "keep"
}

variable "via_aggregator" {
  type = bool
}

variable "loki" {
  type = object({
    host        = string
    port        = number
    uri         = string
    tls         = bool
    tls_verify  = bool
    tenant_id   = string
    internal_ca = bool
  })
}

variable "ca_mount_path" {
  type = string
}

variable "aggregator" {
  type = object({
    host = string
    port = number
  })
}

variable "tuning" {
  type = object({
    flush              = number
    refresh_interval   = number
    rotate_wait        = number
    mem_buf_limit      = string
    kube_buffer_size   = string
    log_level          = string
    exclude_namespaces = list(string)
    static_labels      = map(string)
    output_workers     = number
  })
}

variable "chart" {
  type = object({
    image_repository   = string
    image_tag          = string
    agent_config_map   = string
    events_config_map  = string
    credentials_secret = string
    ca_secret          = string
    forward_key_secret = string
    agent_resources    = any
    events_resources   = any
    service_monitor    = bool
    selinux_type       = string
  })
}
