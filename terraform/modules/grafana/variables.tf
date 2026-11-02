variable "namespace" {
  description = "Namespace Grafana runs in."
  type        = string
}

variable "chart" {
  description = "Grafana chart source and version."
  type = object({
    repository = string
    version    = string
  })
}

variable "settings" {
  description = "Grafana settings (see the root module's grafana variable)."
  type = object({
    replicas          = number
    image_tag         = string
    persistence_size  = string
    ingress           = any
    root_url          = string
    ini_overrides     = any
    resources         = any
    node_selector     = map(string)
    tolerations       = list(map(string))
    extra_values_yaml = string
  })
}

variable "image_registry" {
  description = "Registry mirror for chart images. Empty string keeps the chart defaults."
  type        = string
}

variable "storage_class" {
  description = "StorageClass for the Grafana volume. Empty string uses the cluster default."
  type        = string
}

variable "loki" {
  description = "Loki datasource endpoint and user."
  type = object({
    url  = string
    user = string
  })
}

variable "loki_password" {
  description = "Password for the Loki datasource."
  type        = string
  sensitive   = true
}

variable "loki_tls" {
  description = "The Loki datasource URL uses the internal CA (passed separately from the PEM because the PEM is only known after apply)."
  type        = bool
}

variable "ca_cert_pem" {
  description = "CA that signed the Loki gateway certificate. Ignored when loki_tls is false."
  type        = string
}

variable "cloudwatch" {
  description = "CloudWatch datasource for the EKS audit log."
  type = object({
    enabled                     = bool
    region                      = string
    audit_log_group_arn         = string
    audit_log_group_name        = string
    service_account_annotations = map(string)
  })
}

variable "agents_namespace" {
  description = "Namespace of the pod-lifecycle watcher, used by the dashboard query."
  type        = string
}

variable "admin_credentials_revision" {
  description = "Change to generate a new Grafana admin password."
  type        = number
  default     = 1
}
