# Aggregator tier: agents forward here (TLS + shared key, with acknowledgements) and it
# pushes to Loki. When Loki is slow, the backlog builds on these volumes instead of on the
# node agents, so losing a node loses about one flush interval of logs (FINDINGS.md round 4).
# The Fluent Bit chart only renders DaemonSets and Deployments, hence a plain StatefulSet.

locals {
  aggregator_labels = {
    "app.kubernetes.io/name"      = local.aggregator_name
    "app.kubernetes.io/component" = "aggregator"
    "app.kubernetes.io/part-of"   = "logging"
  }
}

# The aggregator's forward listener always uses TLS, with a CA of its own: this module issues
# the certificate, so it does not depend on whoever runs Loki.
module "aggregator_tls" {
  source = "../internal-tls"
  count  = var.aggregator.enabled ? 1 : 0

  common_name           = "${var.cluster_name} Fluent Bit aggregator CA"
  server_validity_hours = var.tls.server_validity_hours
  early_renewal_hours   = var.tls.early_renewal_hours
  servers = {
    aggregator = {
      dns_names = [
        "${local.aggregator_name}.${var.namespace}.svc.cluster.local",
        "${local.aggregator_name}.${var.namespace}.svc",
      ]
    }
  }
}

resource "random_password" "forward_shared_key" {
  count = var.aggregator.enabled ? 1 : 0

  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "forward_key" {
  count = var.aggregator.enabled ? 1 : 0

  metadata {
    name      = local.forward_key_secret
    namespace = var.namespace
  }

  data = {
    "shared-key" = random_password.forward_shared_key[0].result
  }
}

resource "kubernetes_secret_v1" "aggregator_tls" {
  count = var.aggregator.enabled ? 1 : 0

  metadata {
    name      = "${local.aggregator_name}-tls"
    namespace = var.namespace
  }

  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = module.aggregator_tls[0].servers["aggregator"].cert_pem
    "tls.key" = module.aggregator_tls[0].servers["aggregator"].private_key_pem
  }
}

resource "kubernetes_config_map_v1" "aggregator" {
  count = var.aggregator.enabled ? 1 : 0

  metadata {
    name      = "${local.aggregator_name}-config"
    namespace = var.namespace
  }

  data = {
    "fluent-bit.yaml" = module.values.aggregator_config_yaml
  }
}

resource "kubernetes_service_account_v1" "aggregator" {
  count = var.aggregator.enabled ? 1 : 0

  metadata {
    name      = local.aggregator_name
    namespace = var.namespace
    labels    = local.aggregator_labels
  }

  automount_service_account_token = false
}

resource "kubernetes_service_v1" "aggregator" {
  count = var.aggregator.enabled ? 1 : 0

  metadata {
    name      = local.aggregator_name
    namespace = var.namespace
    labels    = local.aggregator_labels
  }

  spec {
    selector = local.aggregator_labels

    port {
      name        = "forward"
      port        = local.aggregator_port
      target_port = "forward"
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_stateful_set_v1" "aggregator" {
  count = var.aggregator.enabled ? 1 : 0

  metadata {
    name      = local.aggregator_name
    namespace = var.namespace
    labels    = local.aggregator_labels
  }

  spec {
    service_name          = local.aggregator_name
    replicas              = var.aggregator.replicas
    pod_management_policy = "Parallel"

    selector {
      match_labels = local.aggregator_labels
    }

    template {
      metadata {
        labels = local.aggregator_labels
        annotations = {
          "checksum/config" = sha256(module.values.aggregator_config_yaml)
        }
      }

      spec {
        service_account_name             = kubernetes_service_account_v1.aggregator[0].metadata[0].name
        automount_service_account_token  = false
        priority_class_name              = "system-cluster-critical"
        termination_grace_period_seconds = 60

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534
          fs_group        = 65534

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "kubernetes.io/hostname"
              label_selector {
                match_labels = local.aggregator_labels
              }
            }
          }
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.aggregator_labels
          }
        }

        container {
          name    = "fluent-bit"
          image   = "${var.image.repository}:${var.image.tag}"
          command = ["/fluent-bit/bin/fluent-bit"]
          args    = ["--config=/fluent-bit/etc/conf/fluent-bit.yaml"]

          port {
            name           = "forward"
            container_port = local.aggregator_port
            protocol       = "TCP"
          }

          port {
            name           = "http"
            container_port = 2020
            protocol       = "TCP"
          }

          env {
            name  = "CLUSTER_NAME"
            value = var.cluster_name
          }

          env {
            name = "LOKI_USERNAME"
            value_from {
              secret_key_ref {
                name = local.credentials_secret
                key  = "username"
              }
            }
          }

          env {
            name = "LOKI_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.credentials_secret
                key  = "password"
              }
            }
          }

          env {
            name = "FORWARD_SHARED_KEY"
            value_from {
              secret_key_ref {
                name = local.forward_key_secret
                key  = "shared-key"
              }
            }
          }

          resources {
            requests = var.aggregator.resources.requests
            limits   = var.aggregator.resources.limits
          }

          readiness_probe {
            http_get {
              path = "/api/v2/health"
              port = "http"
            }
            period_seconds = 10
          }

          liveness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            period_seconds    = 20
            failure_threshold = 6
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/fluent-bit/etc/conf"
            read_only  = true
          }

          volume_mount {
            name       = "tls"
            mount_path = "/fluent-bit/tls"
            read_only  = true
          }

          volume_mount {
            name       = "buffer"
            mount_path = "/var/lib/fluent-bit-aggregator"
          }

          dynamic "volume_mount" {
            for_each = var.loki.internal_ca ? [1] : []
            content {
              name       = "internal-ca"
              mount_path = local.ca_mount_path
              read_only  = true
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.aggregator[0].metadata[0].name
          }
        }

        volume {
          name = "tls"
          secret {
            secret_name  = kubernetes_secret_v1.aggregator_tls[0].metadata[0].name
            default_mode = "0440"
          }
        }

        dynamic "volume" {
          for_each = var.loki.internal_ca ? [1] : []
          content {
            name = "internal-ca"
            secret {
              secret_name  = local.ca_secret
              default_mode = "0444"
            }
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "buffer"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class == "" ? null : var.storage_class

        resources {
          requests = {
            storage = var.aggregator.storage_size
          }
        }
      }
    }

    persistent_volume_claim_retention_policy {
      when_deleted = "Retain"
      when_scaled  = "Retain"
    }
  }

  depends_on = [
    kubernetes_secret_v1.loki_credentials,
    kubernetes_secret_v1.forward_key,
    kubernetes_secret_v1.internal_ca,
  ]
}

resource "kubernetes_pod_disruption_budget_v1" "aggregator" {
  count = var.aggregator.enabled && var.aggregator.replicas > 1 ? 1 : 0

  metadata {
    name      = local.aggregator_name
    namespace = var.namespace
  }

  spec {
    max_unavailable = "1"
    selector {
      match_labels = local.aggregator_labels
    }
  }
}
