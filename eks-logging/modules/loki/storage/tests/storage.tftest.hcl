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
  tiering     = { tenants = ["test-cluster"] }
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

run "chunks_move_hot_to_warm_and_index_stays_standard" {
  command = apply

  # Loki stores chunks under "<tenant>/" and the TSDB index under "index/". Only the chunks may
  # change class: the index is read by every query and is small.
  assert {
    condition = anytrue([for r in aws_s3_bucket_lifecycle_configuration.this["chunks"].rule : (
      r.id == "tier-chunks-test-cluster" &&
      r.filter[0].and[0].prefix == "test-cluster/" &&
      r.filter[0].and[0].object_size_greater_than == 1048576 &&
      length(r.transition) == 1 &&
      one(r.transition).days == 30 && one(r.transition).storage_class == "GLACIER_IR"
    )])
    error_message = "Chunks under the tenant prefix must move to GLACIER_IR after 30 days, large objects only."
  }

  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.this["ruler"].rule : !startswith(r.id, "tier-")])
    error_message = "The ruler bucket is never tiered."
  }

  assert {
    condition     = alltrue([for l in aws_s3_bucket_lifecycle_configuration.this : l.transition_default_minimum_object_size == "all_storage_classes_128K"])
    error_message = "Objects under 128 KB must never transition."
  }
}

run "archive_tier_adds_second_transition" {
  command = apply

  variables {
    tiering = {
      tenants = ["test-cluster"]
      archive = { enabled = true, after_days = 180 }
    }
  }

  assert {
    condition = anytrue([for r in aws_s3_bucket_lifecycle_configuration.this["chunks"].rule : (
      r.id == "tier-chunks-test-cluster" &&
      length(r.transition) == 2 &&
      contains([for t in r.transition : "${t.storage_class}@${t.days}"], "DEEP_ARCHIVE@180")
    )])
    error_message = "With the archive tier on, chunks move on to DEEP_ARCHIVE at after_days."
  }
}

run "tiering_off_leaves_chunks_in_standard" {
  command = apply

  variables {
    tiering = { enabled = false, tenants = ["test-cluster"] }
  }

  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.this["chunks"].rule : !startswith(r.id, "tier-")])
    error_message = "No transition rules when tiering is disabled."
  }
}

run "rejects_archive_before_glacier_ir_minimum" {
  command = plan

  variables {
    tiering = {
      tenants = ["test-cluster"]
      archive = { enabled = true, after_days = 100 }
    }
  }

  expect_failures = [var.tiering]
}

run "rejects_unqueryable_warm_class" {
  command = plan

  variables {
    tiering = { tenants = ["test-cluster"], warm_storage_class = "DEEP_ARCHIVE" }
  }

  expect_failures = [var.tiering]
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
