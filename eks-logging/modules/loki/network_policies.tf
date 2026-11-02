# Ingress rules for Loki's pods. Every policy selects pods of the "loki" release only, so the
# rules are the same whether Loki has a namespace to itself or shares one with the agents.
# The VPC CNI admits kubelet health probes from the node on its own, so no node ranges are
# needed. Egress stays open: Loki needs S3, STS and DNS, and AWS endpoints have no stable CIDRs.

locals {
  loki_pods = {
    "app.kubernetes.io/name"     = "loki"
    "app.kubernetes.io/instance" = "loki"
  }

  # A load balancer in front of the gateway connects from addresses in the VPC.
  gateway_cidr_blocks = distinct(concat(
    var.network_policy.extra_ingress_cidr_blocks,
    local.gateway_exposed ? var.network_policy.vpc_cidr_blocks : [],
  ))
}

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "loki-default-deny-ingress"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = local.loki_pods
    }
    policy_types = ["Ingress"]
  }
}

# Loki components talk to each other (memberlist on 7946, gRPC on 9095, HTTP on 3100) and to
# the memcached caches.
resource "kubernetes_network_policy_v1" "allow_internal" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "loki-allow-internal"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = local.loki_pods
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = local.loki_pods
        }
      }
    }
  }
}

# Clients reach Loki only through the gateway, which is where authentication happens.
resource "kubernetes_network_policy_v1" "allow_gateway_clients" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "loki-allow-gateway-clients"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = merge(local.loki_pods, { "app.kubernetes.io/component" = "gateway" })
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = tostring(module.values.gateway_service.port)
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.network_policy.clients
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value.namespace }
          }
          dynamic "pod_selector" {
            for_each = length(from.value.pod_labels) > 0 ? [from.value.pod_labels] : []
            content {
              match_labels = pod_selector.value
            }
          }
        }
      }

      dynamic "from" {
        for_each = local.gateway_cidr_blocks
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }
  }
}

# Prometheus scraping of Loki's HTTP metrics endpoint from the listed namespaces.
resource "kubernetes_network_policy_v1" "allow_monitoring" {
  count = var.network_policy.enabled && length(var.network_policy.monitoring_namespaces) > 0 ? 1 : 0

  metadata {
    name      = "loki-allow-monitoring"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = local.loki_pods
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "3100"
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
