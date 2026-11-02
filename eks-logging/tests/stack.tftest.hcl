# Whole-stack checks with every provider mocked: nothing touches AWS or a cluster. They prove
# the components wire together, switch off cleanly and reject bad combinations; they do not
# prove that AWS or Kubernetes would accept the result.

mock_provider "aws" {
  mock_data "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/test-cluster"
      endpoint              = "https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
      certificate_authority = [{ data = "ZmFrZS1jYQ==" }]
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }] }]
      vpc_config            = [{ vpc_id = "vpc-0123456789abcdef0" }]
    }
  }
  mock_data "aws_vpc" {
    defaults = {
      cidr_block_associations = [{ cidr_block = "10.0.0.0/16" }, { cidr_block = "100.64.0.0/16" }]
    }
  }
  mock_data "aws_eks_addon" {
    defaults = { configuration_values = "{\"enableNetworkPolicy\":\"true\"}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  cluster_name = "test-cluster"
  aws_region   = "us-east-1"
  environment  = "dev"
}

run "defaults_loki_and_fluent_bit_without_grafana" {
  command = plan

  assert {
    condition     = output.loki.gateway_url == "https://loki-gateway.loki.svc.cluster.local:8080"
    error_message = "Agents reach Loki through the TLS gateway, on the container port."
  }

  assert {
    condition     = output.grafana == null && length(module.grafana) == 0
    error_message = "Grafana is off by default (Amazon Managed Grafana is the expected UI)."
  }

  assert {
    condition     = output.fluent_bit.pushes_to == "https://loki-gateway.loki.svc.cluster.local:8080/loki/api/v1/push"
    error_message = "Fluent Bit pushes to this stack's gateway when no endpoint is given."
  }

  assert {
    condition     = tomap(local.namespaces) == tomap({ loki = "restricted", logging = "privileged" })
    error_message = "Only the namespaces of enabled components exist; only the agents' one is privileged."
  }
}

run "filesystem_storage_rejects_several_replicas" {
  command = plan

  variables {
    loki = { monolithic_replicas = 3 }
  }

  expect_failures = [var.loki]
}

run "filesystem_storage_rejects_distributed_mode" {
  command = plan

  variables {
    loki = { deployment_mode = "Distributed" }
  }

  expect_failures = [var.loki]
}

run "rejects_unknown_storage_backend" {
  command = plan

  variables {
    loki = { storage = { backend = "gcs" } }
  }

  expect_failures = [var.loki]
}

run "hot_warm_tiers_on_s3" {
  command = plan

  variables {
    loki = { storage = { backend = "s3" } }
  }

  assert {
    condition = (
      output.loki.storage_tiers.warm_class == "GLACIER_IR" &&
      output.loki.storage_tiers.warm_after == 30 &&
      output.loki.storage_tiers.archive_class == null &&
      output.loki.storage_tiers.query_lookback == "2160h" &&
      output.loki.storage_tiers.deletion_mode == "filter-and-delete"
    )
    error_message = "Chunks go to Glacier Instant Retrieval after 30 days and stay queryable for the full 90-day retention."
  }
}

run "archive_tier_stops_queries_before_archived_chunks" {
  command = plan

  variables {
    loki = {
      retention_period = "17520h" # 2 years
      storage = {
        backend = "s3"
        tiering = { archive = { enabled = true, after_days = 365 } }
      }
    }
  }

  # Loki cannot read Deep Archive objects; a query reaching them would fail, and so would a
  # delete request that rewrites chunks.
  assert {
    condition = (
      output.loki.storage_tiers.archive_class == "DEEP_ARCHIVE" &&
      output.loki.storage_tiers.query_lookback == "8736h" &&
      output.loki.storage_tiers.deletion_mode == "filter-only"
    )
    error_message = "With the archive tier on, queries stop a day before archiving and deletes become query-time filters."
  }
}

run "rejects_archive_after_retention" {
  command = plan

  variables {
    loki = {
      retention_period = "2160h"
      storage = {
        backend = "s3"
        tiering = { archive = { enabled = true, after_days = 365 } }
      }
    }
  }

  expect_failures = [var.loki]
}

run "network_policies_are_generated_from_the_components" {
  command = plan

  assert {
    condition = (
      module.loki[0].network_policy.default_deny &&
      contains(module.loki[0].network_policy.client_namespaces, "logging") &&
      !contains(module.loki[0].network_policy.client_namespaces, "grafana")
    )
    error_message = "Loki denies ingress by default and admits the Fluent Bit namespace (Grafana only when it is deployed)."
  }

  assert {
    condition     = length(module.loki[0].network_policy.gateway_cidr_blocks) == 0
    error_message = "VPC ranges must not reach the gateway while it is cluster-internal."
  }
}

run "internal_nlb_for_amazon_managed_grafana" {
  command = plan

  variables {
    loki = {
      gateway = {
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
          }
        }
        extra_dns_names = ["loki.internal.example.com"]
      }
    }
  }

  assert {
    condition = (
      output.amazon_managed_grafana.loki_url == "https://loki.internal.example.com:8080" &&
      output.amazon_managed_grafana.needs_ca_cert
    )
    error_message = "An NLB passes TLS through, so Managed Grafana needs the DNS name in the certificate and the internal CA."
  }

  assert {
    condition     = toset(module.loki[0].network_policy.gateway_cidr_blocks) == toset(["10.0.0.0/16", "100.64.0.0/16"])
    error_message = "The load balancer's VPC addresses must be admitted to the gateway port, read from the cluster's VPC."
  }
}

run "load_balancer_needs_a_certificate_name" {
  command = plan

  variables {
    loki = { gateway = { service = { type = "LoadBalancer" } } }
  }

  expect_failures = [var.loki]
}

run "loki_and_agents_share_a_namespace" {
  command = plan

  variables {
    loki = { namespace = "logging" }
  }

  assert {
    condition     = tomap(local.namespaces) == tomap({ logging = "privileged" })
    error_message = "A shared namespace is created once, at the level the agents need."
  }

  assert {
    condition     = output.loki.gateway_url == "https://loki-gateway.logging.svc.cluster.local:8080"
    error_message = "The gateway address follows the namespace."
  }
}

run "fluent_bit_only_to_an_external_loki" {
  command = plan

  variables {
    loki = { enabled = false }
    fluent_bit = {
      loki_endpoint = {
        host     = "loki.central.example.com"
        username = "team-a"
      }
    }
    external_loki_password = "not-a-real-password"
  }

  assert {
    condition     = output.loki == null && length(module.loki) == 0
    error_message = "No Loki resources when Loki is disabled."
  }

  assert {
    condition     = output.fluent_bit.pushes_to == "https://loki.central.example.com:443/loki/api/v1/push"
    error_message = "Fluent Bit pushes to the given endpoint."
  }

  assert {
    condition     = tomap(local.namespaces) == tomap({ logging = "privileged" })
    error_message = "Only the agents' namespace is created."
  }
}

run "loki_only_without_collection" {
  command = plan

  variables {
    fluent_bit = { enabled = false }
  }

  assert {
    condition     = output.fluent_bit == null && length(module.fluent_bit) == 0 && length(module.pod_lifecycle) == 0
    error_message = "No collection resources when Fluent Bit is disabled."
  }

  assert {
    condition     = length(local.loki_clients) == 0
    error_message = "With no clients deployed, nothing is admitted to the gateway."
  }
}

run "fluent_bit_needs_somewhere_to_push" {
  command = plan

  variables {
    loki = { enabled = false }
  }

  expect_failures = [var.fluent_bit]
}

run "eviction_protections_on_by_default" {
  command = plan

  # The settings that made evicted, force-deleted and short-lived pods' logs arrive in the lab
  # (FINDINGS.md): fast file discovery, a long read window on deleted files, a disk buffer,
  # the event collector and the pod-lifecycle watcher.
  assert {
    condition = (
      tonumber(yamldecode(module.fluent_bit[0].agent_config_yaml).pipeline.inputs[0].refresh_interval) <= 0.5 &&
      yamldecode(module.fluent_bit[0].agent_config_yaml).pipeline.inputs[0].rotate_wait >= 300 &&
      yamldecode(module.fluent_bit[0].agent_config_yaml).pipeline.inputs[0]["storage.type"] == "filesystem" &&
      yamldecode(module.fluent_bit[0].agent_values_yaml).priorityClassName == "system-node-critical" &&
      module.fluent_bit[0].events_enabled &&
      length(module.pod_lifecycle) == 1
    )
    error_message = "An eviction protection is off by default."
  }
}

run "everything_enabled" {
  command = plan

  variables {
    aws_identity_mode = "pod_identity"
    fluent_bit = {
      aggregator = { enabled = true }
      log_keeper = { enabled = true, image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/log-keeper:1.0.0" }
    }
    network_policies = { monitoring_namespaces = ["monitoring"] }
    grafana          = { enabled = true, cloudwatch_audit = true }
    loki = {
      deployment_mode = "Distributed"
      storage         = { backend = "s3" }
      gateway = {
        ingress = {
          enabled     = true
          host        = "loki.internal.example.com"
          annotations = { "alb.ingress.kubernetes.io/scheme" = "internal" }
        }
      }
    }
  }

  assert {
    condition     = output.fluent_bit.aggregator_address == "fluent-bit-aggregator.logging.svc.cluster.local:24224" && output.fluent_bit.source_mode == "keep"
    error_message = "Agents read kept files and forward to the aggregator when both are on."
  }

  assert {
    condition     = output.amazon_managed_grafana.loki_url == "https://loki.internal.example.com" && !output.amazon_managed_grafana.needs_ca_cert
    error_message = "Behind an ALB with an ACM certificate, clients need no private CA."
  }

  assert {
    condition     = contains([for c in local.loki_clients : c.namespace], "grafana")
    error_message = "Grafana is admitted to the gateway when deployed."
  }
}

run "rejects_simple_scalable" {
  command = plan

  variables {
    loki = { deployment_mode = "SimpleScalable" }
  }

  expect_failures = [var.loki]
}

run "keeper_needs_image" {
  command = plan

  variables {
    fluent_bit = { log_keeper = { enabled = true } }
  }

  expect_failures = [var.fluent_bit]
}

run "aggregator_needs_internal_tls" {
  command = plan

  variables {
    fluent_bit   = { aggregator = { enabled = true } }
    internal_tls = { enabled = false }
  }

  expect_failures = [var.fluent_bit]
}

run "grafana_ha_needs_database" {
  command = plan

  variables {
    grafana = { enabled = true, replicas = 2 }
  }

  expect_failures = [var.grafana]
}

run "fluent_bit_tag_must_be_pinned" {
  command = plan

  variables {
    fluent_bit = { image = { tag = "latest" } }
  }

  expect_failures = [var.fluent_bit]
}

# Rendered values hold a bcrypt hash, known only after apply. These run last so that the state
# they leave cannot affect the plan-only runs above. Every provider is still mocked.
# The stack must be usable without S3: a bucket, key or role here costs money and needs
# permissions that the person applying may not have.
run "no_s3_kms_or_iam_by_default" {
  command = apply

  assert {
    condition     = output.loki.buckets == null && output.loki.kms_key_arn == null && output.loki.role_arn == null
    error_message = "Filesystem storage creates no bucket, KMS key or IAM role."
  }

  assert {
    condition = (
      yamldecode(nonsensitive(module.loki[0].values[0])).loki.storage.type == "filesystem" &&
      yamldecode(nonsensitive(module.loki[0].values[0])).singleBinary.replicas == 1
    )
    error_message = "Loki keeps its logs on one volume, with one replica."
  }

  # 90 days of logs would not fit: 50 GB/day of raw logs fills 100Gi in about two weeks.
  assert {
    condition = (
      output.loki.storage_tiers.retention_period == "168h" &&
      yamldecode(nonsensitive(module.loki[0].values[0])).singleBinary.persistence.size == "100Gi"
    )
    error_message = "Filesystem storage defaults to 7 days on a 100Gi volume."
  }
}

run "filesystem_storage_takes_explicit_sizes" {
  command = apply

  variables {
    loki = { retention_period = "24h", persistence_size = "20Gi" }
  }

  assert {
    condition = (
      output.loki.storage_tiers.retention_period == "24h" &&
      yamldecode(nonsensitive(module.loki[0].values[0])).singleBinary.persistence.size == "20Gi"
    )
    error_message = "Explicit retention and volume size win over the backend's defaults."
  }
}

run "s3_backend_brings_buckets_tiers_and_replicas" {
  command = apply

  variables {
    loki = { storage = { backend = "s3" } }
  }

  assert {
    condition = (
      output.loki.kms_key_arn != null &&
      yamldecode(nonsensitive(module.loki[0].values[0])).loki.storage.type == "s3" &&
      yamldecode(nonsensitive(module.loki[0].values[0])).singleBinary.replicas == 3 &&
      yamldecode(nonsensitive(module.loki[0].values[0])).singleBinary.persistence.size == "50Gi"
    )
    error_message = "With S3, Loki gets its KMS key and bucket config, three replicas and the smaller volume."
  }
}
