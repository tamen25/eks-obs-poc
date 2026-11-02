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
