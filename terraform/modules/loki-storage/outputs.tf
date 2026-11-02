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
