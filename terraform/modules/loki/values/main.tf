locals {
  monolithic = var.deployment_mode == "Monolithic"

  # Loki needs at least as many replicas as its replication factor to accept writes.
  replication_factor = local.monolithic ? min(3, var.monolithic_replicas) : min(3, var.distributed_replicas.ingester)

  resources = {
    requests = { cpu = var.resources.requests_cpu, memory = var.resources.requests_memory }
    limits   = { memory = var.resources.limits_memory }
  }

  # Distributed components other than the ingester (which gets the main sizing).
  component_resources = {
    requests = { cpu = var.component_resources.requests_cpu, memory = var.component_resources.requests_memory }
    limits   = { memory = var.component_resources.limits_memory }
  }

  # CPU limits are left off on purpose throughout: CFS throttling stalls Loki's request paths
  # well before the node is out of CPU. Requests reserve the capacity.
  gateway_resources = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { memory = "256Mi" }
  }
  exporter_resources = {
    requests = { cpu = "10m", memory = "32Mi" }
    limits   = { memory = "64Mi" }
  }

  # The chart gives the caches their own ServiceAccount with automountServiceAccountToken: false,
  # which the pods inherit; the pod template just does not repeat the field.
  memcached_check_exceptions = {
    "checkov.io/skip1" = "CKV_K8S_38=ServiceAccount loki-memcached sets automountServiceAccountToken false; the pod inherits it"
  }

  # Spread replicas across availability zones when nodes allow it, without blocking scheduling.
  zone_spread = [{
    maxSkew           = 1
    topologyKey       = "topology.kubernetes.io/zone"
    whenUnsatisfiable = "ScheduleAnyway"
    labelSelector = {
      matchLabels = {
        "app.kubernetes.io/component" = "single-binary"
        "app.kubernetes.io/name"      = "loki"
        "app.kubernetes.io/instance"  = "loki"
      }
    }
  }]

  gateway_port = var.gateway.tls_enabled ? 443 : 80

  gateway_tls_snippet = <<-EOT
    ssl_certificate     /etc/nginx/tls/tls.crt;
    ssl_certificate_key /etc/nginx/tls/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:1m;
    ssl_session_timeout 10m;
  EOT

  gateway_tls_volumes = [for name in ["gateway-tls"] : {
    name   = name
    secret = { secretName = var.gateway.tls_secret_name, defaultMode = 288 } # 0440
  } if var.gateway.tls_enabled]

  gateway_tls_mounts = [for name in ["gateway-tls"] : {
    name      = name
    mountPath = "/etc/nginx/tls"
    readOnly  = true
  } if var.gateway.tls_enabled]

  distributed_components = {
    distributor    = var.distributed_replicas.distributor
    querier        = var.distributed_replicas.querier
    queryFrontend  = var.distributed_replicas.query_frontend
    queryScheduler = var.distributed_replicas.query_scheduler
    indexGateway   = var.distributed_replicas.index_gateway
    compactor      = var.distributed_replicas.compactor
    ruler          = var.distributed_replicas.ruler
  }

  values = merge(
    {
      deploymentMode   = var.deployment_mode
      fullnameOverride = "loki"

      global = merge(
        { priorityClassName = null },
        var.image_registry == "" ? {} : { imageRegistry = var.image_registry },
      )

      # The test pod pulls grafana/loki-helm-test:latest; the canary needs its own credentials.
      test       = { enabled = false }
      lokiCanary = { enabled = false }

      # Loki itself never calls the Kubernetes API. IRSA and Pod Identity inject their own
      # token volume, so the default API token stays unmounted.
      serviceAccount = {
        create                       = true
        name                         = var.service_account_name
        annotations                  = var.service_account_annotations
        automountServiceAccountToken = false
      }
      defaults = { automountServiceAccountToken = false }

      # The rules sidecar watches ConfigMaps and Secrets cluster-wide, which needs a
      # ClusterRole that can read every Secret. Rules can live in the ruler bucket instead.
      sidecar = { rules = { enabled = false } }

      memcachedExporter = { resources = local.exporter_resources }

      loki = merge(
        {
          auth_enabled = true
          # The gateway maps each authenticated user to the X-Scope-OrgID of the same name, so a
          # client cannot pick another tenant by setting the header itself.
          tenants = [{ name = var.tenant_id, passwordHash = var.tenant_password_bcrypt }]

          schemaConfig = {
            configs = [{
              from         = var.schema_from
              store        = "tsdb"
              object_store = "s3"
              schema       = "v13"
              index        = { prefix = "loki_index_", period = "24h" }
            }]
          }

          storage = {
            type        = "s3"
            bucketNames = { chunks = var.bucket_names.chunks, ruler = var.bucket_names.ruler }
            s3 = merge(
              { region = var.region, s3ForcePathStyle = false, insecure = false },
              var.s3_endpoint == "" ? {} : { endpoint = var.s3_endpoint },
            )
          }

          commonConfig = { replication_factor = local.replication_factor }

          limits_config = {
            retention_period            = var.retention_period
            max_query_lookback          = var.retention_period
            ingestion_rate_mb           = var.limits.ingestion_rate_mb
            ingestion_burst_size_mb     = var.limits.ingestion_burst_size_mb
            per_stream_rate_limit       = var.limits.per_stream_rate_limit
            per_stream_rate_limit_burst = var.limits.per_stream_rate_limit_burst
            # Without truncation, a line over the limit is dropped and the pushing client still
            # gets a success response, so nobody notices (seen in the eviction lab with a 1 MB
            # stack trace).
            max_line_size               = var.limits.max_line_size
            max_line_size_truncate      = var.limits.max_line_size_truncate
            max_global_streams_per_user = var.limits.max_global_streams_per_user
            max_query_series            = var.limits.max_query_series
            query_timeout               = var.limits.query_timeout
            allow_structured_metadata   = true
            volume_enabled              = true
            reject_old_samples          = true
            reject_old_samples_max_age  = "168h"
          }

          compactor = {
            retention_enabled    = true
            delete_request_store = "s3"
            working_directory    = "/var/loki/compactor"
          }

          analytics = { reporting_enabled = false }
        },
        var.image_tag == "" ? {} : { image = { tag = var.image_tag } },
      )

      gateway = {
        enabled   = true
        replicas  = var.gateway.replicas
        basicAuth = { enabled = true }
        service   = { port = local.gateway_port, type = "ClusterIP" }
        nginxConfig = {
          ssl           = var.gateway.tls_enabled
          serverSnippet = var.gateway.tls_enabled ? local.gateway_tls_snippet : ""
          # The chart default (4M) rejects larger agent batches with HTTP 413.
          clientMaxBodySize = var.gateway.client_max_body_size
        }
        extraVolumes      = local.gateway_tls_volumes
        extraVolumeMounts = local.gateway_tls_mounts
        readinessProbe = {
          httpGet             = { path = "/", port = "http", scheme = var.gateway.tls_enabled ? "HTTPS" : "HTTP" }
          initialDelaySeconds = 15
          timeoutSeconds      = 1
        }
        # /livez is served by nginx itself, outside Basic Auth.
        livenessProbe = {
          httpGet          = { path = "/livez", port = "http", scheme = var.gateway.tls_enabled ? "HTTPS" : "HTTP" }
          periodSeconds    = 30
          failureThreshold = 6
          timeoutSeconds   = 2
        }
        resources = local.gateway_resources
        # Access-log exporter sidecar.
        metrics = { resources = local.exporter_resources }
        annotations = {
          "checkov.io/skip1" = "CKV_K8S_40=The nginx image runs as UID 101; the chart's file paths assume it"
        }
        nodeSelector = var.node_selector
        tolerations  = var.tolerations
        ingress = {
          enabled          = var.gateway.ingress.enabled
          ingressClassName = var.gateway.ingress.class_name
          annotations      = var.gateway.ingress.annotations
          hosts            = [{ host = var.gateway.ingress.host, paths = [{ path = "/", pathType = "Prefix" }] }]
          tls              = var.gateway.ingress.tls_secret == "" ? [] : [{ secretName = var.gateway.ingress.tls_secret, hosts = [var.gateway.ingress.host] }]
        }
      }

      singleBinary = {
        replicas                  = local.monolithic ? var.monolithic_replicas : 0
        resources                 = local.resources
        nodeSelector              = var.node_selector
        tolerations               = var.tolerations
        topologySpreadConstraints = local.zone_spread
        persistence = {
          enabled      = true
          size         = var.persistence.size
          storageClass = var.persistence.storage_class
        }
      }

      # SimpleScalable targets: unused (deprecated mode), kept at zero explicitly.
      write   = { replicas = 0 }
      read    = { replicas = 0 }
      backend = { replicas = 0 }

      ingester = {
        replicas     = local.monolithic ? 0 : var.distributed_replicas.ingester
        resources    = local.resources
        nodeSelector = var.node_selector
        tolerations  = var.tolerations
        persistence = {
          enabled = !local.monolithic
          claims  = [{ name = "data", accessModes = ["ReadWriteOnce"], size = var.persistence.size, storageClass = var.persistence.storage_class }]
        }
        zoneAwareReplication = { enabled = !local.monolithic && var.zone_aware_ingesters }
      }

      chunksCache = {
        enabled         = var.caches.chunks_enabled
        allocatedMemory = var.caches.chunks_memory_mb
        nodeSelector    = var.node_selector
        tolerations     = var.tolerations
        annotations     = local.memcached_check_exceptions
      }
      resultsCache = {
        enabled         = var.caches.results_enabled
        allocatedMemory = var.caches.results_memory_mb
        nodeSelector    = var.node_selector
        tolerations     = var.tolerations
        annotations     = local.memcached_check_exceptions
      }

      monitoring = {
        serviceMonitor = { enabled = var.service_monitor }
      }
    },
    {
      for name, replicas in local.distributed_components : name => {
        replicas     = local.monolithic ? 0 : replicas
        resources    = local.component_resources
        nodeSelector = var.node_selector
        tolerations  = var.tolerations
      }
    },
  )
}
