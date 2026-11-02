# Ingress rules for the Loki namespace. Egress stays open: Loki needs S3, STS and DNS, and
# AWS endpoints have no stable CIDRs to pin.

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "default-deny-ingress"
    namespace = var.namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# Loki components talk to each other (memberlist on 7946, gRPC on 9095, HTTP on 3100) and to
# the memcached caches inside the namespace.
resource "kubernetes_network_policy_v1" "allow_same_namespace" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "allow-same-namespace"
    namespace = var.namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {}
      }

      # Kubelet liveness and readiness probes come from the node's own address. Some CNIs
      # exempt them from NetworkPolicy, some do not; listing the node subnets covers both.
      dynamic "from" {
        for_each = var.network_policy.node_cidr_blocks
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }
  }
}

# Clients (log agents, Grafana, anything listed) reach Loki only through the gateway, which is
# where authentication happens.
resource "kubernetes_network_policy_v1" "allow_gateway_clients" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "allow-gateway-clients"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/component" = "gateway"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "8080"
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.network_policy.client_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }

      dynamic "from" {
        for_each = var.network_policy.extra_ingress_cidr_blocks
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
    name      = "allow-monitoring"
    namespace = var.namespace
  }

  spec {
    pod_selector {}
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
