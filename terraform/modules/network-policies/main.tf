# Ingress rules for the agents and Grafana namespaces; the Loki namespace has its own in
# modules/loki. Egress stays open: the agents push to Loki and the aggregator, Grafana queries
# Loki and CloudWatch, and AWS endpoints have no stable CIDRs to pin.

locals {
  namespaces = merge(
    { agents = var.agents_namespace },
    var.grafana_namespace == "" ? {} : { grafana = var.grafana_namespace },
  )
}

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  for_each = local.namespaces

  metadata {
    name      = "default-deny-ingress"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_probes_and_metrics" {
  for_each = local.namespaces

  metadata {
    name      = "allow-probes-and-metrics"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = each.key == "grafana" ? "3000" : "2020"
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.monitoring_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }

      dynamic "from" {
        for_each = var.node_cidr_blocks
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "allow_aggregator_forward" {
  count = var.aggregator_enabled ? 1 : 0

  metadata {
    name      = "allow-aggregator-forward"
    namespace = var.agents_namespace
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "fluent-bit-aggregator" }
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "24224"
        protocol = "TCP"
      }
      from {
        pod_selector {}
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "allow_grafana_ingress" {
  count = var.grafana_namespace == "" ? 0 : 1

  metadata {
    name      = "allow-grafana-ingress"
    namespace = var.grafana_namespace
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "grafana" }
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "3000"
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.grafana_ingress_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }

      dynamic "from" {
        for_each = var.grafana_ingress_cidr_blocks
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }
  }
}
