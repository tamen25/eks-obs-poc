variable "aws_region" {
  description = "Region of the Amazon Managed Grafana workspace."
  type        = string
}

variable "workspace_id" {
  description = "ID of the existing Amazon Managed Grafana workspace (g-xxxxxxxxxx)."
  type        = string

  validation {
    condition     = can(regex("^g-[a-z0-9]{10}$", var.workspace_id))
    error_message = "workspace_id must look like g-0123456789."
  }
}

variable "grafana_token" {
  description = <<-EOT
    Service account token with the Admin role on the workspace. Create a short-lived one per
    run (README: "Amazon Managed Grafana"); it is only used during plan and apply.
  EOT
  type        = string
  sensitive   = true
}

variable "loki" {
  description = <<-EOT
    How the workspace reaches Loki: the eks-logging stack's amazon_managed_grafana output
    (url, user), plus loki_ca_cert_pem when needs_ca_cert is true.
  EOT
  type = object({
    url         = string
    user        = string
    ca_cert_pem = optional(string, "")
  })

  validation {
    condition     = startswith(var.loki.url, "https://")
    error_message = "loki.url must be https: the datasource sends the tenant password with every query."
  }
}

variable "loki_password" {
  description = "The eks-logging stack's loki_tenant_password output."
  type        = string
  sensitive   = true
}

variable "datasource" {
  description = "Name and UID of the Loki datasource created in the workspace."
  type = object({
    name = optional(string, "Loki (EKS logs)")
    uid  = optional(string, "eks-logs-loki")
  })
  default = {}
}

variable "dashboards" {
  description = "Folder for the eviction dashboard, and the namespace where pod-lifecycle runs (fluent_bit.namespace)."
  type = object({
    enabled          = optional(bool, true)
    folder           = optional(string, "EKS logging")
    agents_namespace = optional(string, "logging")
  })
  default = {}
}
