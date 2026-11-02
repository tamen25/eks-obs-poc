variable "namespaces" {
  description = <<-EOT
    Namespaces to create, keyed by role, with their Pod Security Admission level.
    The log agents read node files through hostPath, which only the "privileged" level allows,
    so they get a namespace of their own and nothing else runs there.
  EOT
  type = map(object({
    name         = string
    pod_security = string
    extra_labels = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for ns in values(var.namespaces) : contains(["privileged", "baseline", "restricted"], ns.pod_security)])
    error_message = "pod_security must be privileged, baseline or restricted."
  }
}

variable "storage_class" {
  description = <<-EOT
    Encrypted gp3 StorageClass for Loki, Grafana and aggregator volumes (EBS CSI driver).
    kms_key_arn = null uses the account's default EBS key. A customer-managed key also needs the
    EBS CSI driver's role to be allowed to use it.
  EOT
  type = object({
    create      = bool
    name        = string
    kms_key_arn = optional(string)
  })
}

variable "labels" {
  description = "Labels added to every namespace."
  type        = map(string)
  default     = {}
}
