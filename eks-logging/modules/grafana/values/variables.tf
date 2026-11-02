# Pure module: Helm values for grafana-community/grafana. No providers.

variable "replicas" {
  type = number
}

variable "image_registry" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "admin_secret" {
  type = string
}

variable "persistence" {
  type = object({
    enabled       = bool
    size          = string
    storage_class = string
  })
}

variable "ingress" {
  type = object({
    enabled     = bool
    class_name  = string
    host        = string
    annotations = map(string)
    tls_secret  = string
  })
}

variable "root_url" {
  type = string
}

variable "ini_overrides" {
  type = any
}

variable "loki_datasource" {
  type = object({
    url             = string
    user            = string
    password_secret = string
    tls_ca_secret   = string
  })
}

variable "cloudwatch" {
  type = object({
    enabled = bool
    region  = string
  })
}

variable "service_account_annotations" {
  type = map(string)
}

variable "dashboards_config_map" {
  type = string
}

variable "resources" {
  type = any
}

variable "node_selector" {
  type = map(string)
}

variable "tolerations" {
  type = list(map(string))
}

variable "extra_values_yaml" {
  type = string
}
