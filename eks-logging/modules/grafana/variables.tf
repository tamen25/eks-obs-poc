variable "namespace" {
  description = "Namespace Grafana runs in. It must already exist."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the CloudWatch IAM role name."
  type        = string
}

variable "cluster" {
  description = "The EKS cluster, for the IAM trust policy and the audit log group name."
  type = object({
    name              = string
    arn               = string
    oidc_provider_arn = string
    oidc_issuer_url   = string
  })
}

variable "identity" {
  description = "How Grafana gets AWS credentials for CloudWatch (irsa or pod_identity)."
  type = object({
    mode                     = string
    permissions_boundary_arn = optional(string)
  })
}

variable "aws_region" {
  description = "Region of the cluster's CloudWatch log group."
  type        = string
}

variable "tags" {
  description = "Tags added to every AWS resource."
  type        = map(string)
  default     = {}
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
    cloudwatch_audit  = bool
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
  description = "Loki datasource: URL, user, and whether to verify it with a private CA."
  type = object({
    url         = string
    user        = string
    internal_ca = bool # separate from the PEM, which is only known after apply
    ca_cert_pem = string
  })
}

variable "loki_password" {
  description = "Password for the Loki datasource."
  type        = string
  sensitive   = true
}

variable "agents_namespace" {
  description = "Namespace of the pod-lifecycle watcher, used by the evicted-pods dashboard query."
  type        = string
}

variable "network_policy" {
  description = <<-EOT
    Ingress NetworkPolicies for Grafana's pods. ingress_namespaces (an ingress controller) and
    ingress_cidr_blocks may reach port 3000; with the ALB ingress on, so may vpc_cidr_blocks.
  EOT
  type = object({
    enabled               = bool
    ingress_namespaces    = list(string)
    ingress_cidr_blocks   = list(string)
    monitoring_namespaces = list(string)
    vpc_cidr_blocks       = list(string)
  })
}

variable "admin_credentials_revision" {
  description = "Change to generate a new Grafana admin password."
  type        = number
  default     = 1
}
