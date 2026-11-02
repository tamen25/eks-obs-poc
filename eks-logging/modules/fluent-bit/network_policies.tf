# Ingress rules for this module's pods. Nothing connects to the agents except Prometheus, and
# only the agents connect to the aggregator. Policies select this module's pods by label, so
# they are unaffected by other components sharing the namespace. Egress stays open: the agents
# call the Kubernetes API and push to Loki or the aggregator.

locals {
  agent_pods      = { "app.kubernetes.io/name" = "fluent-bit" } # agent and event collector
  aggregator_pods = { "app.kubernetes.io/name" = local.aggregator_name }

  policy_targets = merge(
    { "fluent-bit" = local.agent_pods },
    var.aggregator.enabled ? { (local.aggregator_name) = local.aggregator_pods } : {},
    var.log_keeper.enabled ? { "log-keeper" = local.log_keeper_labels } : {},
  )
  metrics_targets = { for k, v in local.policy_targets : k => v if k != "log-keeper" }
}

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  for_each = var.network_policy.enabled ? local.policy_targets : {}

  metadata {
    name      = "${each.key}-default-deny-ingress"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = each.value
    }
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_metrics" {
  for_each = var.network_policy.enabled && length(var.network_policy.monitoring_namespaces) > 0 ? local.metrics_targets : {}

  metadata {
    name      = "${each.key}-allow-metrics"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = each.value
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "2020"
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.network_policy.monitoring_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "allow_aggregator_forward" {
  count = var.network_policy.enabled && var.aggregator.enabled ? 1 : 0

  metadata {
    name      = "${local.aggregator_name}-allow-forward"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = local.aggregator_pods
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = tostring(local.aggregator_port)
        protocol = "TCP"
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/instance" = "fluent-bit" }
        }
      }
    }
  }
}
