# Whole-stack checks with every provider mocked: nothing touches AWS or a cluster. They prove
# the modules wire together and the guards reject bad combinations; they do not prove that
# AWS or Kubernetes would accept the result.

mock_provider "aws" {
  mock_data "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/test-cluster"
      endpoint              = "https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
      certificate_authority = [{ data = "ZmFrZS1jYQ==" }]
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }] }]
    }
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

run "defaults_plan" {
  command = plan

  assert {
    condition     = output.loki_gateway_url == "https://loki-gateway.loki.svc.cluster.local:443"
    error_message = "Agents and Grafana reach Loki through the TLS gateway by default."
  }

  assert {
    condition     = output.loki_tenant == "test-cluster"
    error_message = "The tenant defaults to the cluster name."
  }

  assert {
    condition     = output.aggregator_address == null
    error_message = "The aggregator is off by default."
  }
}

run "everything_enabled_plan" {
  command = plan

  variables {
    aws_identity_mode = "pod_identity"
    aggregator        = { enabled = true }
    log_keeper        = { enabled = true, image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/log-keeper:1.0.0" }
    network_policies  = { enabled = true, node_cidr_blocks = ["10.0.0.0/16"] }
    grafana           = { cloudwatch_audit = true }
    loki = {
      deployment_mode = "Distributed"
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
    condition     = output.aggregator_address == "fluent-bit-aggregator.logging.svc.cluster.local:24224"
    error_message = "Agents forward to the aggregator when it is enabled."
  }
}

run "endpoint_override_plan" {
  command = plan

  variables {
    fluent_bit = {
      loki_endpoint_override = {
        host     = "loki.central.example.com"
        username = "team-a"
      }
    }
    loki_endpoint_password = "not-a-real-password"
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
    log_keeper = { enabled = true }
  }

  expect_failures = [var.log_keeper]
}

run "aggregator_needs_internal_tls" {
  command = plan

  variables {
    aggregator   = { enabled = true }
    internal_tls = { enabled = false }
  }

  expect_failures = [var.aggregator]
}

run "grafana_ha_needs_database" {
  command = plan

  variables {
    grafana = { replicas = 2 }
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
