variable "name_prefix" {
  description = "Prefix for bucket names and the KMS alias. Bucket names get the account ID and region appended, so the result is globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit."
  }
}

variable "kms" {
  description = <<-EOT
    Customer-managed KMS key for bucket encryption. With create = true the module creates one
    (rotation on). Otherwise key_arn must point at an existing key whose policy lets IAM grant use.
  EOT
  type = object({
    create                  = optional(bool, true)
    key_arn                 = optional(string)
    deletion_window_in_days = optional(number, 30)
  })
  default = {}

  validation {
    condition     = var.kms.create || var.kms.key_arn != null
    error_message = "Set kms.key_arn when kms.create is false."
  }

  validation {
    condition     = var.kms.deletion_window_in_days >= 7 && var.kms.deletion_window_in_days <= 30
    error_message = "kms.deletion_window_in_days must be between 7 and 30."
  }
}

variable "versioning" {
  description = "Keep previous object versions. Loki deletes chunks on retention, so noncurrent versions expire after noncurrent_version_expiration_days."
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep noncurrent object versions when versioning is on."
  type        = number
  default     = 7
}

variable "expiration_backstop_days" {
  description = <<-EOT
    S3 lifecycle expiration for all objects, as a backstop in case the Loki compactor stops
    applying retention. Must be longer than Loki's retention or S3 deletes live data. null disables it.
  EOT
  type        = number
  default     = null
}

variable "tiering" {
  description = <<-EOT
    Storage tiers for Loki chunks, applied by S3 lifecycle rules on the chunks bucket:
      hot     - S3 Standard for the first hot_days. No read fee.
      warm    - warm_storage_class after that. GLACIER_IR and STANDARD_IA return data in
                milliseconds, so Loki still queries it; each read costs a retrieval fee.
      archive - optional GLACIER or DEEP_ARCHIVE after archive.after_days. Loki cannot read
                these until the objects are restored, so the Loki module stops queries at
                that age.
    tenants lists the Loki tenant IDs (each tenant's chunks live under "<tenant>/").
    min_object_size_bytes keeps small chunks in Standard, where a transition fee would cost
    more than the storage it saves.
  EOT
  type = object({
    enabled               = optional(bool, true)
    tenants               = list(string)
    hot_days              = optional(number, 30)
    warm_storage_class    = optional(string, "GLACIER_IR")
    min_object_size_bytes = optional(number, 1048576)
    archive = optional(object({
      enabled       = optional(bool, false)
      storage_class = optional(string, "DEEP_ARCHIVE")
      after_days    = optional(number, 365)
    }), {})
  })

  validation {
    condition     = contains(["GLACIER_IR", "STANDARD_IA"], var.tiering.warm_storage_class)
    error_message = "tiering.warm_storage_class must be GLACIER_IR or STANDARD_IA: Loki can only read classes that return data immediately."
  }

  validation {
    condition     = var.tiering.hot_days >= (var.tiering.warm_storage_class == "STANDARD_IA" ? 30 : 1)
    error_message = "tiering.hot_days must be at least 1 (30 for STANDARD_IA, which S3 enforces)."
  }

  validation {
    condition     = contains(["GLACIER", "DEEP_ARCHIVE"], var.tiering.archive.storage_class)
    error_message = "tiering.archive.storage_class must be GLACIER (Flexible Retrieval) or DEEP_ARCHIVE."
  }

  # S3 rejects a rule that leaves the warm class before its minimum storage duration
  # (90 days for GLACIER_IR, 30 for STANDARD_IA).
  validation {
    condition = !var.tiering.archive.enabled || (
      var.tiering.archive.after_days >= var.tiering.hot_days + (var.tiering.warm_storage_class == "GLACIER_IR" ? 90 : 30)
    )
    error_message = "tiering.archive.after_days must be at least hot_days + 90 for GLACIER_IR (hot_days + 30 for STANDARD_IA)."
  }

  validation {
    condition     = var.tiering.min_object_size_bytes >= 131072
    error_message = "tiering.min_object_size_bytes must be at least 131072 (128 KB); smaller transitions cost more than they save."
  }

  validation {
    condition     = length(var.tiering.tenants) > 0 && alltrue([for t in var.tiering.tenants : can(regex("^[a-zA-Z0-9_.-]{1,64}$", t))])
    error_message = "tiering.tenants must list at least one valid Loki tenant ID."
  }
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete non-empty buckets. Leave false outside throwaway environments."
  type        = bool
  default     = false
}

variable "access_log_bucket" {
  description = "Existing bucket that receives S3 server access logs for the Loki buckets. null disables access logging."
  type        = string
  default     = null
}

variable "allowed_vpc_endpoint_ids" {
  description = <<-EOT
    When non-empty, the bucket policy denies data access that does not arrive through one of these
    S3 gateway VPC endpoints (administrative principals listed in admin_principal_arns are exempt).
  EOT
  type        = list(string)
  default     = []
}

variable "admin_principal_arns" {
  description = "IAM principals exempt from the VPC endpoint restriction, so that Terraform and break-glass roles can still manage the buckets."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}
