output "bucket_names" {
  description = "Loki bucket names by purpose (chunks, ruler)."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "bucket_arns" {
  description = "Loki bucket ARNs by purpose (chunks, ruler)."
  value       = { for k, b in aws_s3_bucket.this : k => b.arn }
}

output "kms_key_arn" {
  description = "KMS key that encrypts the buckets."
  value       = local.kms_key_arn
}

output "region" {
  description = "Region the buckets live in."
  value       = local.region
}

output "chunk_tiers" {
  description = "Storage class schedule for chunk objects, in days since they were written."
  value = {
    hot_class     = "STANDARD"
    warm_class    = var.tiering.enabled ? var.tiering.warm_storage_class : null
    warm_after    = var.tiering.enabled ? var.tiering.hot_days : null
    archive_class = var.tiering.enabled && var.tiering.archive.enabled ? var.tiering.archive.storage_class : null
    archive_after = var.tiering.enabled && var.tiering.archive.enabled ? var.tiering.archive.after_days : null
  }
}
