data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # OSS Loki needs two buckets. "admin" exists only for Grafana Enterprise Logs.
  buckets = {
    chunks = "${var.name_prefix}-chunks-${local.account_id}-${local.region}"
    ruler  = "${var.name_prefix}-ruler-${local.account_id}-${local.region}"
  }

  kms_key_arn = var.kms.create ? aws_kms_key.this[0].arn : var.kms.key_arn
}

resource "aws_kms_key" "this" {
  count = var.kms.create ? 1 : 0

  description             = "Loki object storage (${var.name_prefix})"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.kms.deletion_window_in_days

  # Account-level IAM decides who may use the key; the Loki role gets kms:GenerateDataKey and
  # kms:Decrypt through its own policy, scoped to calls made by S3 in this region.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableIAMPolicies"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = var.tags
}

resource "aws_kms_alias" "this" {
  count = var.kms.create ? 1 : 0

  name          = "alias/${var.name_prefix}-loki"
  target_key_id = aws_kms_key.this[0].key_id
}

resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_21:Versioning is set by aws_s3_bucket_versioning from var.versioning (default on); checkov cannot resolve the variable.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles storage cost for logs; add it per environment if DR policy requires it.
  #checkov:skip=CKV2_AWS_62:Nothing consumes object events for Loki chunks; notifications would only add cost.
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { "loki-bucket" = each.key })
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
    # One data key per bucket instead of one KMS call per object: Loki writes many small objects.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = var.versioning ? "Enabled" : "Disabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  dynamic "rule" {
    for_each = var.expiration_backstop_days == null ? [] : [var.expiration_backstop_days]
    content {
      id     = "retention-backstop"
      status = "Enabled"
      filter {}
      expiration {
        days = rule.value
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_logging" "this" {
  for_each = var.access_log_bucket == null ? {} : aws_s3_bucket.this

  bucket        = each.value.id
  target_bucket = var.access_log_bucket
  target_prefix = "s3-access/${each.value.id}/"
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "DenyInsecureTransport"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:*"
          Resource  = [each.value.arn, "${each.value.arn}/*"]
          Condition = { Bool = { "aws:SecureTransport" = "false" } }
        },
        {
          Sid       = "DenyOutdatedTLS"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:*"
          Resource  = [each.value.arn, "${each.value.arn}/*"]
          Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
        },
      ],
      length(var.allowed_vpc_endpoint_ids) == 0 ? [] : [{
        Sid       = "DenyDataAccessOutsideVpcEndpoints"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource  = [each.value.arn, "${each.value.arn}/*"]
        Condition = merge(
          { StringNotEquals = { "aws:sourceVpce" = var.allowed_vpc_endpoint_ids } },
          length(var.admin_principal_arns) == 0 ? {} : { ArnNotLike = { "aws:PrincipalArn" = var.admin_principal_arns } },
        )
      }],
    )
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}
