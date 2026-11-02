# Offline: the AWS provider is mocked, so these runs check what the module would request,
# not what AWS would accept.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/mock" }
  }
}

variables {
  name_prefix = "test-logs"
}

run "buckets_are_private_encrypted_and_tls_only" {
  command = apply

  assert {
    condition     = output.bucket_names.chunks == "test-logs-chunks-123456789012-us-east-1"
    error_message = "Bucket names must carry account and region so they are globally unique."
  }

  assert {
    condition = alltrue([for b in aws_s3_bucket_public_access_block.this : (
      b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets
    )])
    error_message = "Every public access block setting must be on."
  }

  assert {
    condition = alltrue([for c in aws_s3_bucket_server_side_encryption_configuration.this : (
      one(c.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" && one(c.rule).bucket_key_enabled
    )])
    error_message = "Buckets must default to SSE-KMS with a bucket key."
  }

  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation
    error_message = "The KMS key must rotate."
  }

  assert {
    condition = alltrue([for p in aws_s3_bucket_policy.this : (
      anytrue([for s in jsondecode(p.policy).Statement :
        s.Effect == "Deny" && s.Principal == "*" && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
      ]) &&
      anytrue([for s in jsondecode(p.policy).Statement :
        s.Effect == "Deny" && try(s.Condition.NumericLessThan["s3:TlsVersion"], "") == "1.2"
      ])
    )])
    error_message = "Bucket policies must deny plain HTTP and TLS older than 1.2."
  }

  assert {
    condition     = alltrue([for p in aws_s3_bucket_policy.this : !strcontains(p.policy, "aws:sourceVpce")])
    error_message = "No VPC endpoint restriction unless endpoint IDs are given."
  }

  assert {
    condition     = alltrue([for o in aws_s3_bucket_ownership_controls.this : one(o.rule).object_ownership == "BucketOwnerEnforced"])
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }
}

run "vpc_endpoint_restriction_and_backstop" {
  command = apply

  variables {
    allowed_vpc_endpoint_ids = ["vpce-0123456789abcdef0"]
    admin_principal_arns     = ["arn:aws:iam::123456789012:role/terraform"]
    expiration_backstop_days = 61
  }

  assert {
    condition     = alltrue([for p in aws_s3_bucket_policy.this : strcontains(p.policy, "vpce-0123456789abcdef0") && strcontains(p.policy, "role/terraform")])
    error_message = "The policy must restrict data access to the VPC endpoint and exempt admin principals."
  }

  assert {
    condition     = alltrue([for l in aws_s3_bucket_lifecycle_configuration.this : anytrue([for r in l.rule : r.id == "retention-backstop" && r.expiration[0].days == 61])])
    error_message = "The retention backstop rule must be present when configured."
  }
}

run "rejects_bad_prefix" {
  command = plan

  variables {
    name_prefix = "Bad_Prefix"
  }

  expect_failures = [var.name_prefix]
}

run "external_key_requires_arn" {
  command = plan

  variables {
    kms = { create = false }
  }

  expect_failures = [var.kms]
}
