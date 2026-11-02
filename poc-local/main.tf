locals {
  loki_gateway = "http://loki-gateway.observability.svc.cluster.local"
  tempo_url    = "http://tempo.observability.svc.cluster.local:3200"
  otlp_tempo   = "tempo.observability.svc.cluster.local:4317"
}

############################################################################################
# Namespaces
############################################################################################

resource "kubernetes_namespace_v1" "this" {
  for_each = {
    # The agents read node log files through hostPath, which only "privileged" admits.
    logging       = "privileged"
    observability = "baseline"
    demo          = "baseline"
    scenarios     = "baseline" # ./run.sh scenarios

  }

  metadata {
    name = each.key
    labels = {
      "pod-security.kubernetes.io/enforce" = each.value
      "app.kubernetes.io/part-of"          = "logging-poc"
    }
  }
}

############################################################################################
# Loki: single binary, chunks and index on its own volume
############################################################################################

resource "random_password" "tenant" {
  length  = 32
  special = false
}

resource "helm_release" "loki" {
  name       = "loki"
  namespace  = kubernetes_namespace_v1.this["observability"].metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = var.charts.loki

  values = [yamlencode({
    deploymentMode   = "SingleBinary"
    fullnameOverride = "loki"

    loki = {
      auth_enabled = true
      # The gateway maps the Basic Auth user to the X-Scope-OrgID of the same name, so a client
      # cannot pick another tenant by setting the header itself (as in eks-logging).
      tenants      = [{ name = var.tenant, passwordHash = random_password.tenant.bcrypt_hash }]
      commonConfig = { replication_factor = 1 }
      storage      = { type = "filesystem" }
      schemaConfig = {
        configs = [{
          from         = "2024-01-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index        = { prefix = "loki_index_", period = "24h" }
        }]
      }
      # The eks-logging defaults, so lines behave the same here.
      limits_config = {
        retention_period            = var.retention.logs
        retention_stream            = [{ selector = "{namespace=~\".+-(uat|preprod)\"}", priority = 1, period = var.retention.nonprod }]
        ingestion_rate_mb           = 16
        ingestion_burst_size_mb     = 32
        per_stream_rate_limit       = "5MB"
        per_stream_rate_limit_burst = "20MB"
        max_line_size               = "256KB"
        max_line_size_truncate      = true
        allow_structured_metadata   = true
        volume_enabled              = true
        reject_old_samples          = true
        reject_old_samples_max_age  = "168h"
      }
      compactor = {
        retention_enabled    = true
        delete_request_store = "filesystem"
        working_directory    = "/var/loki/compactor"
      }
      analytics = { reporting_enabled = false }
    }

    singleBinary = {
      replicas    = 1
      persistence = { enabled = true, size = var.storage_size }
      resources   = { requests = { cpu = "200m", memory = "512Mi" }, limits = { memory = "2Gi" } }
    }
    write   = { replicas = 0 }
    read    = { replicas = 0 }
    backend = { replicas = 0 }

    gateway = {
      enabled   = true
      basicAuth = { enabled = true }
      # The chart default (4M) rejects larger agent batches with HTTP 413.
      nginxConfig = { clientMaxBodySize = "16M" }
    }

    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    test         = { enabled = false }
    lokiCanary   = { enabled = false }
    sidecar      = { rules = { enabled = false } }
  })]

  wait    = true
  timeout = 600
}

############################################################################################
# Tempo: single binary, traces on its own volume
############################################################################################

resource "helm_release" "tempo" {
  name       = "tempo"
  namespace  = kubernetes_namespace_v1.this["observability"].metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "tempo"
  version    = var.charts.tempo

  values = [yamlencode({
    tempo = {
      retention        = var.retention.traces
      reportingEnabled = false
      storage = {
        trace = {
          backend = "local"
          local   = { path = "/var/tempo/traces" }
          wal     = { path = "/var/tempo/wal" }
        }
      }
      # OTLP only: the collector is the single way in.
      receivers = {
        otlp = { protocols = { grpc = { endpoint = "0.0.0.0:4317" }, http = { endpoint = "0.0.0.0:4318" } } }
      }
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "1Gi" } }
    }
    persistence = { enabled = true, size = var.storage_size }
  })]

  wait    = true
  timeout = 600
}

############################################################################################
# OpenTelemetry collector: receives OTLP from apps, adds Kubernetes metadata, sends to Tempo
############################################################################################

resource "helm_release" "otel" {
  name       = "otel-collector"
  namespace  = kubernetes_namespace_v1.this["observability"].metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.charts.otel

  values = [yamlencode({
    mode             = "deployment"
    fullnameOverride = "otel-collector"
    image            = { repository = "otel/opentelemetry-collector-k8s" }
    command          = { name = "otelcol-k8s" }

    # Adds k8s.namespace.name, k8s.pod.name and friends to every span, which Grafana uses to
    # find the logs of a span's pod.
    presets = { kubernetesAttributes = { enabled = true } }

    # Replaces the chart's default config instead of merging into it, so no debug exporters
    # or unused receivers are left running.
    alternateConfig = {
      extensions = { health_check = { endpoint = "$${env:MY_POD_IP}:13133" } }
      receivers = {
        otlp = { protocols = {
          grpc = { endpoint = "$${env:MY_POD_IP}:4317" }
          http = { endpoint = "$${env:MY_POD_IP}:4318" }
        } }
      }
      processors = {
        memory_limiter = { check_interval = "5s", limit_percentage = 80, spike_limit_percentage = 25 }
        batch          = {}
      }
      exporters = {
        "otlp/tempo" = { endpoint = local.otlp_tempo, tls = { insecure = true } }
      }
      service = {
        extensions = ["health_check"]
        pipelines = {
          traces = { receivers = ["otlp"], processors = ["memory_limiter", "batch"], exporters = ["otlp/tempo"] }
        }
      }
    }

    ports = {
      jaeger-compact = { enabled = false }
      jaeger-thrift  = { enabled = false }
      jaeger-grpc    = { enabled = false }
      zipkin         = { enabled = false }
    }
    resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } }
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.tempo]
}

############################################################################################
# Fluent Bit: the eks-logging module, unchanged, pushing to the in-cluster Loki gateway
############################################################################################

module "fluent_bit" {
  source = "../eks-logging/modules/fluent-bit"

  namespace    = kubernetes_namespace_v1.this["logging"].metadata[0].name
  cluster_name = var.cluster_name
  chart        = { repository = "https://fluent.github.io/helm-charts", version = var.charts.fluent_bit }
  image        = { repository = "cr.fluentbit.io/fluent/fluent-bit", tag = "5.1.3" }

  loki = {
    host        = "loki-gateway.observability.svc.cluster.local"
    port        = 80
    uri         = "/loki/api/v1/push"
    tls         = false
    tls_verify  = false
    tenant_id   = "" # the gateway sets it from the Basic Auth user
    username    = var.tenant
    internal_ca = false
    ca_cert_pem = ""
  }
  loki_password = random_password.tenant.result

  tuning = {
    flush              = 1
    refresh_interval   = 0.5
    rotate_wait        = 300
    mem_buf_limit      = "50MB"
    kube_buffer_size   = "512k"
    log_level          = "info"
    exclude_namespaces = []
    extra_labels       = {}
    output_workers     = 2
    agent_resources    = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = "512Mi" } }
    events_resources   = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    selinux_type       = ""
    service_monitor    = false
  }

  node_logs = {
    enabled      = true
    journal_path = var.journal_path
    units        = ["kubelet.service", "containerd.service"]
    kernel       = true
  }

  aggregator = { enabled = false, replicas = 2, storage_size = "20Gi", resources = {} }
  log_keeper = {
    enabled       = false
    image         = ""
    ttl_minutes   = 60
    max_orphan_mb = 512
    resources     = { requests = {}, limits = {} }
  }
  tls            = { server_validity_hours = 8760, early_renewal_hours = 720 }
  storage_class  = ""
  events_enabled = true
  network_policy = { enabled = true, monitoring_namespaces = [] }

  depends_on = [helm_release.loki]
}

# Logs each pod's final state (eviction reason, disruption condition, OOM, last lines) as
# JSON, which the agents collect: the "why did it end" panels read it. The eks-logging module.
module "pod_lifecycle" {
  source = "../eks-logging/modules/pod-lifecycle"

  namespace = kubernetes_namespace_v1.this["logging"].metadata[0].name
  image     = "docker.io/alpine/k8s:1.34.12"
  resources = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "128Mi" } }
}

############################################################################################
# Grafana: Loki and Tempo data sources, linked both ways by trace ID, and the dashboards
############################################################################################

locals {
  # Written by dashboards/build.py.
  dashboards = { for f in fileset("${path.module}/dashboards", "*.json") : f => file("${path.module}/dashboards/${f}") }
}

resource "kubernetes_config_map_v1" "dashboards" {
  metadata {
    name      = "grafana-dashboards"
    namespace = kubernetes_namespace_v1.this["observability"].metadata[0].name
  }

  data = local.dashboards
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = kubernetes_namespace_v1.this["observability"].metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = var.charts.grafana

  values = [yamlencode({
    adminUser     = "admin"
    adminPassword = random_password.grafana_admin.result
    # No login: anyone who can reach Grafana is an admin. Acceptable because it is only
    # reachable through a port-forward on 127.0.0.1; the admin account stays for the API.
    "grafana.ini" = {
      "auth.anonymous" = { enabled = true, org_role = "Admin" }
      auth             = { disable_login_form = true }
      dashboards       = { default_home_dashboard_path = "/var/lib/grafana/dashboards/poc/1-overview.json" }
    }
    persistence   = { enabled = false }
    testFramework = { enabled = false }

    dashboardProviders = {
      "dashboardproviders.yaml" = {
        apiVersion = 1
        providers = [{
          name            = "poc"
          orgId           = 1
          folder          = "Logging POC"
          type            = "file"
          disableDeletion = true
          editable        = true
          options         = { path = "/var/lib/grafana/dashboards/poc" }
        }]
      }
    }
    dashboardsConfigMaps = { poc = kubernetes_config_map_v1.dashboards.metadata[0].name }
    # Restart Grafana when a dashboard changes, instead of waiting for the volume to refresh.
    podAnnotations = { "checksum/dashboards" = sha256(jsonencode(local.dashboards)) }

    datasources = {
      "datasources.yaml" = {
        apiVersion = 1
        datasources = [
          {
            name          = "Loki"
            uid           = "loki"
            type          = "loki"
            access        = "proxy"
            url           = local.loki_gateway
            isDefault     = true
            basicAuth     = true
            basicAuthUser = var.tenant
            secureJsonData = {
              basicAuthPassword = random_password.tenant.result
            }
            jsonData = {
              # Turns trace_id=<id> in a log line into a link to that trace. Grafana expands
              # $VAR in provisioning files, so the file must say $${__value.raw}: HCL turns
              # the "$${" below into "${", leaving one "$" in front of it.
              derivedFields = [{
                name          = "TraceID"
                matcherType   = "regex"
                matcherRegex  = "trace_id=(\\w+)"
                datasourceUid = "tempo"
                url           = "$$${__value.raw}"
              }]
            }
          },
          {
            name   = "Tempo"
            uid    = "tempo"
            type   = "tempo"
            access = "proxy"
            url    = local.tempo_url
            jsonData = {
              # From a span to the logs of its pod's namespace that carry the same trace ID.
              tracesToLogsV2 = {
                datasourceUid      = "loki"
                filterByTraceID    = true
                spanStartTimeShift = "-5m"
                spanEndTimeShift   = "5m"
                tags               = [{ key = "k8s.namespace.name", value = "namespace" }]
              }
              nodeGraph  = { enabled = true }
              lokiSearch = { datasourceUid = "loki" }
            }
          },
        ]
      }
    }

    resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } }
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.loki, helm_release.tempo]
}

############################################################################################
# Demo service: a trace per fake order, each log line carrying its trace ID
############################################################################################

resource "kubernetes_config_map_v1" "demo" {
  count = var.demo_enabled ? 1 : 0

  metadata {
    name      = "demo-checkout"
    namespace = kubernetes_namespace_v1.this["demo"].metadata[0].name
  }

  data = {
    "app.py" = file("${path.module}/demo/app.py")
  }
}

resource "kubernetes_deployment_v1" "demo" {
  count = var.demo_enabled ? 1 : 0

  metadata {
    name      = "demo-checkout"
    namespace = kubernetes_namespace_v1.this["demo"].metadata[0].name
    labels    = { app = "demo-checkout" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "demo-checkout" }
    }

    template {
      metadata {
        labels = { app = "demo-checkout" }
        # Restart the pod when the script changes.
        annotations = { "checksum/app" = sha256(file("${path.module}/demo/app.py")) }
      }

      spec {
        container {
          name  = "app"
          image = "python:3.12.10-slim"
          # Installs the OpenTelemetry SDK on start (about 20s) so no image has to be built.
          command = ["sh", "-c", "pip install --quiet --no-cache-dir --root-user-action=ignore opentelemetry-sdk==1.27.0 opentelemetry-exporter-otlp-proto-grpc==1.27.0 && exec python -u /app/app.py"]

          env {
            name  = "OTEL_SERVICE_NAME"
            value = "demo-checkout"
          }
          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "http://otel-collector.observability.svc.cluster.local:4317"
          }

          volume_mount {
            name       = "app"
            mount_path = "/app"
            read_only  = true
          }

          resources {
            requests = { cpu = "20m", memory = "96Mi" }
            limits   = { memory = "256Mi" }
          }
        }

        volume {
          name = "app"
          config_map {
            name = kubernetes_config_map_v1.demo[0].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_rollout = false

  depends_on = [helm_release.otel]
}
