# log-keeper hard-links every new container log under /var/log/keep, so the file outlives the
# kubelet deleting the original (eviction, force delete, rotation) and shipper restarts. The
# agent then reads the kept copies (source_mode "keep"). FINDINGS.md round 4.

locals {
  log_keeper_labels = {
    "app.kubernetes.io/name"    = "log-keeper"
    "app.kubernetes.io/part-of" = "logging"
  }
  log_keeper_script = file("${path.module}/files/keeper.sh")
}

resource "kubernetes_config_map_v1" "log_keeper" {
  count = var.log_keeper.enabled ? 1 : 0

  metadata {
    name      = "log-keeper"
    namespace = var.namespace
    labels    = local.log_keeper_labels
  }

  data = {
    "keeper.sh" = local.log_keeper_script
  }
}

resource "kubernetes_daemon_set_v1" "log_keeper" {
  count = var.log_keeper.enabled ? 1 : 0

  metadata {
    name      = "log-keeper"
    namespace = var.namespace
    labels    = local.log_keeper_labels
  }

  spec {
    selector {
      match_labels = local.log_keeper_labels
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "1"
      }
    }

    template {
      metadata {
        labels = local.log_keeper_labels
        annotations = {
          "checksum/script" = sha256(local.log_keeper_script)
        }
      }

      spec {
        automount_service_account_token = false
        # Same footing as the agent: it must outlive the pods whose files it is holding.
        priority_class_name = "system-node-critical"

        toleration {
          operator = "Exists"
        }

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "keeper"
          image   = var.log_keeper.image
          command = ["/bin/sh", "/scripts/keeper.sh"]

          env {
            name  = "TTL_MINUTES"
            value = tostring(var.log_keeper.ttl_minutes)
          }

          env {
            name  = "KEEP_MAX_MB"
            value = tostring(var.log_keeper.max_orphan_mb)
          }

          resources {
            requests = var.log_keeper.resources.requests
            limits   = var.log_keeper.resources.limits
          }

          # Root, because the files and /var/log are root-owned and hard-linking a file needs
          # its owner (or CAP_FOWNER). No capabilities, no privilege escalation, read-only root.
          security_context {
            run_as_user                = 0
            run_as_group               = 0
            run_as_non_root            = false
            privileged                 = false
            allow_privilege_escalation = false
            read_only_root_filesystem  = true

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "varlog"
            mount_path = "/var/log"
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
        }

        volume {
          name = "varlog"
          host_path {
            path = "/var/log"
            type = "Directory"
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.log_keeper[0].metadata[0].name
            default_mode = "0555"
          }
        }
      }
    }
  }
}
