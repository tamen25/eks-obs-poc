locals {
  name = "pod-lifecycle"
  labels = {
    "app.kubernetes.io/name"    = local.name
    "app.kubernetes.io/part-of" = "logging"
  }
  files = {
    "watch.sh"  = file("${path.module}/files/watch.sh")
    "filter.jq" = file("${path.module}/files/filter.jq")
  }
}

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }
}

# Read-only: list and watch pods, nothing else.
resource "kubernetes_cluster_role_v1" "this" {
  metadata {
    name   = local.name
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  metadata {
    name   = local.name
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_config_map_v1" "this" {
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }

  data = local.files
}

resource "kubernetes_deployment_v1" "this" {
  #checkov:skip=CKV_K8S_10:Requests come from var.resources (defaults set in the root module); checkov cannot resolve the variable.
  #checkov:skip=CKV_K8S_12:Memory limit comes from var.resources (default 128Mi); checkov cannot resolve the variable.
  #checkov:skip=CKV_K8S_13:Memory request comes from var.resources (default 32Mi); checkov cannot resolve the variable.
  #checkov:skip=CKV_K8S_11:No CPU limit on purpose: CFS throttling would delay the watch; the CPU request reserves capacity.
  #checkov:skip=CKV_K8S_14:The image tag is a validated variable that rejects latest and untagged references.
  #checkov:skip=CKV_K8S_15:Images are pinned by tag or digest, so IfNotPresent pulls the same image as Always.
  #checkov:skip=CKV_K8S_43:Digest pinning is supported through var.image; the default is a pinned tag.
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          "checksum/files" = sha256(jsonencode(local.files))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.this.metadata[0].name
        priority_class_name  = "system-cluster-critical"

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "watch"
          image   = var.image
          command = ["/bin/sh", "/scripts/watch.sh"]

          # kubectl caches discovery data under $HOME.
          env {
            name  = "HOME"
            value = "/tmp"
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          # The watch pipeline is the whole job: restart the pod if kubectl is no longer running.
          liveness_probe {
            exec {
              command = ["/bin/sh", "-c", "pgrep -f 'kubectl get pods' >/dev/null"]
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }

          readiness_probe {
            exec {
              command = ["/bin/sh", "-c", "pgrep -f 'kubectl get pods' >/dev/null"]
            }
            period_seconds = 15
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
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.this.metadata[0].name
            default_mode = "0444"
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "64Mi"
          }
        }
      }
    }
  }
}
