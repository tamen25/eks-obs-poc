variable "kubeconfig" {
  description = "Kubeconfig file with the POC cluster's context."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Context to deploy into. run.sh creates kind-logging-poc."
  type        = string
  default     = "kind-logging-poc"
}

variable "cluster_name" {
  description = "Value of the cluster label on every log stream."
  type        = string
  default     = "poc"
}

variable "tenant" {
  description = "Loki tenant, and the Basic Auth user that maps to it at the gateway."
  type        = string
  default     = "poc"
}

variable "retention" {
  description = "How long Loki and Tempo keep data. Logs from non-prod namespaces (*-uat, *-preprod) are kept for nonprod only."
  type = object({
    logs    = optional(string, "720h")
    traces  = optional(string, "720h")
    nonprod = optional(string, "168h")
  })
  default = {}
}

variable "storage_size" {
  description = "Persistent volume size for Loki and for Tempo."
  type        = string
  default     = "10Gi"
}

variable "journal_path" {
  description = "Node journal directory. kind nodes use /run/log/journal; EKS AL2023 uses /var/log/journal."
  type        = string
  default     = "/run/log/journal"
}

variable "demo_enabled" {
  description = "Run the demo service that emits traces and logs sharing a trace ID."
  type        = bool
  default     = true
}

variable "charts" {
  description = "Chart versions. Loki, Grafana and Fluent Bit match the eks-logging stack."
  type = object({
    loki       = optional(string, "20.0.2")
    tempo      = optional(string, "3.2.0")
    grafana    = optional(string, "14.2.0")
    fluent_bit = optional(string, "0.58.3")
    otel       = optional(string, "0.176.0")
  })
  default = {}
}
