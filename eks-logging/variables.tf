############################################################################################
# Cluster and account
############################################################################################

variable "cluster_name" {
  description = "Name of the existing EKS cluster to deploy into."
  type        = string
}

variable "aws_region" {
  description = "Region of the cluster. Loki's buckets are created here too."
  type        = string
}

variable "environment" {
  description = "Environment name, used in tags (for example dev, staging, prod)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment must be 2-12 lowercase letters, digits or hyphens."
  }
}

variable "name_prefix" {
  description = "Prefix for AWS resource names. Defaults to \"<cluster>-logs\" when null."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags for every AWS resource."
  type        = map(string)
  default     = {}
}

variable "kubernetes_auth_role_arn" {
  description = "IAM role to assume for `aws eks get-token` when talking to the cluster. null uses the caller's credentials."
  type        = string
  default     = null
}

variable "storage_class" {
  description = "Encrypted gp3 StorageClass for every volume in this stack. Set create = false to use an existing class by name."
  type = object({
    create      = optional(bool, true)
    name        = optional(string, "logging-gp3-encrypted")
    kms_key_arn = optional(string)
  })
  default = {}
}

variable "image_registry_mirror" {
  description = <<-EOT
    Registry host that mirrors the public images (for example an ECR pull-through cache:
    <account>.dkr.ecr.<region>.amazonaws.com/docker-hub). Empty string pulls from the public
    registries. Applies to the Loki and Grafana charts; Fluent Bit uses fluent_bit.image.
  EOT
  type        = string
  default     = ""
}

variable "aws_identity_mode" {
  description = <<-EOT
    How Loki (and Grafana's CloudWatch datasource) get AWS credentials:
      irsa         - IAM Roles for Service Accounts. Grafana documents this for Loki on EKS.
      pod_identity - EKS Pod Identity. Needs the eks-pod-identity-agent add-on. Loki uses the
                     AWS SDK default credential chain, which reads Pod Identity credentials,
                     but Grafana does not document this setup; test it before production.
  EOT
  type        = string
  default     = "irsa"

  validation {
    condition     = contains(["irsa", "pod_identity"], var.aws_identity_mode)
    error_message = "aws_identity_mode must be \"irsa\" or \"pod_identity\"."
  }
}

variable "iam_permissions_boundary_arn" {
  description = "Permissions boundary for the IAM roles this stack creates, if the account requires one."
  type        = string
  default     = null
}

############################################################################################
# Loki (component)
############################################################################################

variable "loki" {
  description = "Loki: storage backend, query and push endpoint. enabled = false skips every Loki resource (point Fluent Bit at another Loki with fluent_bit.loki_endpoint)."
  type = object({
    enabled   = optional(bool, true)
    namespace = optional(string, "loki")

    chart_repository = optional(string, "https://grafana-community.github.io/helm-charts")
    chart_version    = optional(string, "20.0.2")
    image_tag        = optional(string, "")

    # Monolithic: one StatefulSet running every component, scaled horizontally; Grafana's
    # guidance is up to a few tens of GB/day. Distributed: one workload per component, for
    # larger volumes. SimpleScalable is deprecated and left out.
    deployment_mode = optional(string, "Monolithic")
    # null = 1 with filesystem storage (the only count it allows), 3 with S3.
    monolithic_replicas = optional(number)
    distributed_replicas = optional(object({
      distributor     = optional(number, 3)
      ingester        = optional(number, 3)
      querier         = optional(number, 3)
      query_frontend  = optional(number, 2)
      query_scheduler = optional(number, 2)
      index_gateway   = optional(number, 2)
      compactor       = optional(number, 1)
      ruler           = optional(number, 1)
    }), {})
    # Ingester StatefulSet per zone (zone-a/b/c). Needs nodes in three zones.
    zone_aware_ingesters = optional(bool, false)

    # Tenant ID and Basic Auth user. null = the cluster name.
    tenant_id = optional(string)
    # Bump to rotate the tenant password (agents and Grafana pick up the new one on apply).
    credentials_revision = optional(number, 1)

    # Never change after the first deployment: Loki reads older data with this schema.
    schema_from = optional(string, "2025-01-01")
    # How long logs are kept (Loki deletes them after this). null = 168h (7 days) with filesystem
    # storage, where they have to fit on one volume; 2160h (90 days: 30 hot + 60 warm) with S3.
    retention_period = optional(string)

    limits = optional(object({
      ingestion_rate_mb           = optional(number, 16)
      ingestion_burst_size_mb     = optional(number, 32)
      per_stream_rate_limit       = optional(string, "5MB")
      per_stream_rate_limit_burst = optional(string, "20MB")
      max_line_size               = optional(string, "256KB")
      max_line_size_truncate      = optional(bool, true)
      max_global_streams_per_user = optional(number, 10000)
      max_query_series            = optional(number, 1000)
      query_timeout               = optional(string, "300s")
    }), {})

    # null = 100Gi with filesystem storage (it holds every log), 50Gi with S3 (WAL and cache only).
    persistence_size = optional(string)
    # Single binary (Monolithic) or ingesters (Distributed).
    resources = optional(object({
      requests_cpu    = optional(string, "1")
      requests_memory = optional(string, "2Gi")
      limits_memory   = optional(string, "4Gi")
    }), {})
    # Every other Distributed component (distributor, querier, query frontend, ...).
    component_resources = optional(object({
      requests_cpu    = optional(string, "250m")
      requests_memory = optional(string, "512Mi")
      limits_memory   = optional(string, "2Gi")
    }), {})
    # The chunks cache also saves Glacier Instant Retrieval read fees on repeated queries.
    caches = optional(object({
      chunks_enabled    = optional(bool, true)
      chunks_memory_mb  = optional(number, 2048)
      results_enabled   = optional(bool, true)
      results_memory_mb = optional(number, 512)
    }), {})

    node_selector = optional(map(string), {})
    tolerations   = optional(list(map(string)), [])

    gateway = optional(object({
      replicas             = optional(number, 2)
      client_max_body_size = optional(string, "16M")
      # LoadBalancer + AWS Load Balancer Controller annotations gives an internal NLB, for
      # example for Amazon Managed Grafana in the VPC. Put the DNS name clients will use in
      # extra_dns_names so the gateway certificate covers it.
      service = optional(object({
        type        = optional(string, "ClusterIP")
        annotations = optional(map(string), {})
      }), {})
      extra_dns_names = optional(list(string), [])
      # Or an ALB Ingress (TLS terminated with an ACM certificate). When internal TLS is on,
      # also set alb.ingress.kubernetes.io/backend-protocol = HTTPS.
      ingress = optional(object({
        enabled     = optional(bool, false)
        class_name  = optional(string, "alb")
        host        = optional(string, "")
        annotations = optional(map(string), {})
        tls_secret  = optional(string, "")
      }), {})
    }), {})

    storage = optional(object({
      # "filesystem": logs on one EBS volume, one replica, no S3, KMS key or IAM role.
      # "s3": buckets with storage tiers, several replicas. Everything below only applies to s3.
      backend = optional(string, "filesystem")

      kms = optional(object({
        create                  = optional(bool, true)
        key_arn                 = optional(string)
        deletion_window_in_days = optional(number, 30)
      }), {})
      versioning                         = optional(bool, true)
      noncurrent_version_expiration_days = optional(number, 7)
      # Days after which S3 deletes any object regardless of Loki. null = retention + 30 days.
      expiration_backstop_days = optional(number)
      force_destroy            = optional(bool, false)
      access_log_bucket        = optional(string)
      allowed_vpc_endpoint_ids = optional(list(string), [])
      admin_principal_arns     = optional(list(string), [])
      # Custom S3 endpoint (for example an interface VPC endpoint DNS name). Empty = AWS default.
      s3_endpoint = optional(string, "")

      # Hot (S3 Standard) for hot_days, then warm (Glacier Instant Retrieval, still queryable),
      # then optionally an archive class Loki cannot query without a restore.
      tiering = optional(object({
        enabled               = optional(bool, true)
        hot_days              = optional(number, 30)
        warm_storage_class    = optional(string, "GLACIER_IR")
        min_object_size_bytes = optional(number, 1048576)
        archive = optional(object({
          enabled       = optional(bool, false)
          storage_class = optional(string, "DEEP_ARCHIVE")
          after_days    = optional(number, 365)
        }), {})
      }), {})
    }), {})

    service_monitor = optional(bool, false)
    # Raw YAML merged over everything above (escape hatch for chart settings not modelled here).
    extra_values_yaml = optional(string, "")
  })
  default = {}

  validation {
    condition     = contains(["Monolithic", "Distributed"], var.loki.deployment_mode)
    error_message = "loki.deployment_mode must be Monolithic or Distributed (SimpleScalable is deprecated)."
  }

  validation {
    condition     = coalesce(var.loki.monolithic_replicas, 1) >= 1
    error_message = "loki.monolithic_replicas must be at least 1."
  }

  validation {
    condition     = contains(["filesystem", "s3"], var.loki.storage.backend)
    error_message = "loki.storage.backend must be filesystem or s3."
  }

  validation {
    condition     = var.loki.storage.backend == "s3" || (var.loki.deployment_mode == "Monolithic" && coalesce(var.loki.monolithic_replicas, 1) == 1)
    error_message = "Filesystem storage is one volume on one pod: it needs deployment_mode = Monolithic and one replica. Use loki.storage.backend = s3 for more."
  }

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.loki.schema_from))
    error_message = "loki.schema_from must be a YYYY-MM-DD date."
  }

  validation {
    condition     = can(regex("^\\d+h$", coalesce(var.loki.retention_period, "2160h")))
    error_message = "loki.retention_period must be in hours, for example 2160h."
  }

  validation {
    condition     = var.loki.tenant_id == null || can(regex("^[a-zA-Z0-9_.-]{1,64}$", var.loki.tenant_id))
    error_message = "loki.tenant_id may only contain letters, digits, '_', '.' and '-' (max 64)."
  }

  validation {
    condition     = !var.loki.gateway.ingress.enabled || var.loki.gateway.ingress.host != ""
    error_message = "loki.gateway.ingress.host is required when the ingress is enabled."
  }

  validation {
    condition     = contains(["ClusterIP", "LoadBalancer"], var.loki.gateway.service.type)
    error_message = "loki.gateway.service.type must be ClusterIP or LoadBalancer."
  }

  validation {
    condition     = var.loki.gateway.service.type != "LoadBalancer" || !var.internal_tls.enabled || length(var.loki.gateway.extra_dns_names) > 0
    error_message = "A LoadBalancer gateway with internal TLS needs loki.gateway.extra_dns_names: the DNS name clients use must be in the certificate."
  }

  validation {
    condition = !(var.loki.storage.tiering.enabled && var.loki.storage.tiering.archive.enabled) || (
      tonumber(trimsuffix(coalesce(var.loki.retention_period, "2160h"), "h")) / 24 > var.loki.storage.tiering.archive.after_days
    )
    error_message = "With the archive tier on, loki.retention_period must be longer than loki.storage.tiering.archive.after_days."
  }
}

############################################################################################
# Fluent Bit (component): node agents, event collector, aggregator, log-keeper
############################################################################################

variable "fluent_bit" {
  description = "Log collection. enabled = false skips every collection resource."
  type = object({
    enabled = optional(bool, true)
    # Needs Pod Security "privileged" (hostPath). Loki may share it; the namespace is then
    # privileged for Loki too.
    namespace = optional(string, "logging")

    chart_repository = optional(string, "https://fluent.github.io/helm-charts")
    chart_version    = optional(string, "0.58.3")
    image = optional(object({
      repository = optional(string, "cr.fluentbit.io/fluent/fluent-bit")
      tag        = optional(string, "5.1.3")
    }), {})

    # Seconds between scans for new log files. Lines in files already tailed are read on each
    # write regardless. The first attempt of a crash-looping container keeps its log for only
    # about 1s (the kubelet deletes it when the immediate restart exits), so 2s scans missed
    # some; 0.5s caught all of them on kind, for about 1 mCPU more at 115 files.
    refresh_interval = optional(number, 0.5)
    # Seconds a deleted pod log is still read. 5s (Fluent Bit default) lost lines when the
    # agent was behind; 300 did not.
    rotate_wait   = optional(number, 300)
    flush         = optional(number, 1)
    mem_buf_limit = optional(string, "50MB")
    # Kubernetes API response buffer for pod metadata; large pod specs exceed the 32k default.
    kube_buffer_size = optional(string, "512k")
    log_level        = optional(string, "info")
    output_workers   = optional(number, 2)

    # Namespaces whose container logs are not collected.
    exclude_namespaces = optional(list(string), [])
    # Extra static labels on every stream (keep them low-cardinality).
    extra_labels = optional(map(string), {})

    # SELinux type for the agent on nodes that enforce SELinux (for example Bottlerocket may
    # need "super_t" to read /var/log). Empty = none.
    selinux_type = optional(string, "")

    agent_resources = optional(any, {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "512Mi" }
    })
    # Kubernetes events (Evicted, Preempting, Killing, TaintManagerEviction, NodeNotReady).
    events_enabled = optional(bool, true)
    events_resources = optional(any, {
      requests = { cpu = "20m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    })

    service_monitor = optional(bool, false)

    # Agents forward to an aggregator tier (TLS, shared key, acknowledgements) which pushes to
    # Loki, so a Loki slowdown builds backlog on its volumes instead of on the nodes. Limits
    # node-crash loss to about one flush interval (FINDINGS.md round 4).
    aggregator = optional(object({
      enabled      = optional(bool, false)
      replicas     = optional(number, 2)
      storage_size = optional(string, "20Gi")
      resources = optional(object({
        requests = optional(map(string), { cpu = "100m", memory = "256Mi" })
        limits   = optional(map(string), { memory = "1Gi" })
      }), {})
    }), {})

    # Node services log to journald, not /var/log/containers: kubelet (pod admission, image
    # pulls, eviction decisions, PLEG), the container runtime, and the kernel (OOM kills,
    # disk and network errors). Streams: {job="node", unit="<unit>"}, node in structured
    # metadata. EKS AL2023 nodes keep the journal in /var/log/journal; kind keeps it in
    # /run/log/journal.
    node_logs = optional(object({
      enabled      = optional(bool, true)
      journal_path = optional(string, "/var/log/journal")
      units        = optional(list(string), ["kubelet.service", "containerd.service"])
      kernel       = optional(bool, true)
    }), {})

    # Hard-links every new container log so it outlives the kubelet deleting it (eviction,
    # force delete, rotation) and shipper restarts. Needs an image built from images/log-keeper.
    log_keeper = optional(object({
      enabled       = optional(bool, false)
      image         = optional(string, "")
      ttl_minutes   = optional(number, 10)
      max_orphan_mb = optional(number, 1024)
      resources = optional(object({
        requests = optional(map(string), { cpu = "10m", memory = "16Mi" })
        limits   = optional(map(string), { memory = "64Mi" })
      }), {})
    }), {})

    # Push somewhere other than the Loki this stack deploys (required when loki.enabled is
    # false). The password comes from external_loki_password. ca_cert_pem: a private CA to
    # verify it with; empty uses the system CA bundle.
    loki_endpoint = optional(object({
      host        = string
      port        = optional(number, 443)
      uri         = optional(string, "/loki/api/v1/push")
      tls         = optional(bool, true)
      tls_verify  = optional(bool, true)
      tenant_id   = optional(string, "")
      username    = string
      ca_cert_pem = optional(string, "")
    }))
  })
  default = {}

  validation {
    condition     = var.fluent_bit.refresh_interval >= 0.25 && var.fluent_bit.rotate_wait >= 5
    error_message = "fluent_bit.refresh_interval must be >= 0.25 and rotate_wait >= 5."
  }

  validation {
    condition     = var.fluent_bit.image.tag != "" && var.fluent_bit.image.tag != "latest"
    error_message = "fluent_bit.image.tag must be a pinned version."
  }

  validation {
    condition     = !var.fluent_bit.log_keeper.enabled || var.fluent_bit.log_keeper.image != ""
    error_message = "fluent_bit.log_keeper.image is required when log_keeper is enabled (build images/log-keeper)."
  }

  validation {
    condition     = !var.fluent_bit.enabled || var.loki.enabled || var.fluent_bit.loki_endpoint != null
    error_message = "With loki.enabled = false, set fluent_bit.loki_endpoint so the agents have somewhere to push."
  }

  validation {
    condition     = !var.fluent_bit.aggregator.enabled || var.internal_tls.enabled
    error_message = "The aggregator's forward listener always uses TLS: keep internal_tls enabled with it."
  }
}

variable "pod_lifecycle" {
  description = <<-EOT
    Watcher that logs every pod's terminal state (eviction reason, disruption condition, last
    lines) as JSON, collected by the agents. Runs in the Fluent Bit namespace, so it needs
    fluent_bit.enabled.
  EOT
  type = object({
    enabled = optional(bool, true)
    image   = optional(string, "docker.io/alpine/k8s:1.34.12")
    resources = optional(object({
      requests = optional(map(string), { cpu = "10m", memory = "32Mi" })
      limits   = optional(map(string), { memory = "128Mi" })
    }), {})
  })
  default = {}
}

variable "external_loki_password" {
  description = "Password for fluent_bit.loki_endpoint and grafana.loki_datasource_url when they point at a Loki this stack does not deploy."
  type        = string
  default     = ""
  sensitive   = true
}

############################################################################################
# Grafana (component, off by default)
############################################################################################

variable "grafana" {
  description = <<-EOT
    In-cluster Grafana. Off by default: with Amazon Managed Grafana, leave it off and use the
    amazon_managed_grafana output with integrations/amazon-managed-grafana.
  EOT
  type = object({
    enabled          = optional(bool, false)
    namespace        = optional(string, "grafana")
    chart_repository = optional(string, "https://grafana-community.github.io/helm-charts")
    chart_version    = optional(string, "14.2.0")
    image_tag        = optional(string, "")
    # More than one replica needs an external database (set database.* in ini_overrides).
    replicas         = optional(number, 1)
    persistence_size = optional(string, "10Gi")
    root_url         = optional(string, "")
    ingress = optional(object({
      enabled     = optional(bool, false)
      class_name  = optional(string, "alb")
      host        = optional(string, "")
      annotations = optional(map(string), {})
      tls_secret  = optional(string, "")
    }), {})
    # grafana.ini sections, merged per section over the hardened defaults.
    ini_overrides = optional(any, {})
    resources = optional(any, {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { memory = "1Gi" }
    })
    node_selector = optional(map(string), {})
    tolerations   = optional(list(map(string)), [])

    # Query the EKS audit log in CloudWatch (who drained or evicted a pod). Needs control plane
    # audit logging on the cluster.
    cloudwatch_audit = optional(bool, false)

    # Point the Loki datasource somewhere else. Empty = the Loki this stack deploys.
    loki_datasource_url = optional(string, "")

    extra_values_yaml = optional(string, "")
  })
  default = {}

  validation {
    condition     = var.grafana.replicas == 1 || can(var.grafana.ini_overrides.database)
    error_message = "grafana.replicas > 1 needs an external database in grafana.ini_overrides.database."
  }

  validation {
    condition     = !var.grafana.ingress.enabled || var.grafana.ingress.host != ""
    error_message = "grafana.ingress.host is required when the ingress is enabled."
  }

  validation {
    condition     = !var.grafana.enabled || var.loki.enabled || var.grafana.loki_datasource_url != ""
    error_message = "With loki.enabled = false, set grafana.loki_datasource_url."
  }
}

############################################################################################
# Network security
############################################################################################

variable "internal_tls" {
  description = <<-EOT
    TLS for in-cluster log traffic (agents/Grafana -> Loki gateway, agents -> aggregator),
    with private CAs this stack generates. Private keys end up in Terraform state.
  EOT
  type = object({
    enabled               = optional(bool, true)
    server_validity_hours = optional(number, 8760)
    early_renewal_hours   = optional(number, 720)
  })
  default = {}
}

variable "network_policies" {
  description = <<-EOT
    Ingress NetworkPolicies for every component, on by default. Terraform knows where each
    component runs, so the rules are generated: agents and Grafana may reach the Loki gateway,
    agents may reach the aggregator, and nothing else gets in. The VPC's CIDRs are read from
    the cluster and allowed only to load-balanced ports (Loki gateway, Grafana) when those are
    exposed. Enforced only when the VPC CNI has enableNetworkPolicy = "true" (a check warns
    otherwise). The lists below are for anything extra.
  EOT
  type = object({
    enabled                      = optional(bool, true)
    monitoring_namespaces        = optional(list(string), [])
    extra_loki_client_namespaces = optional(list(string), [])
    extra_loki_cidr_blocks       = optional(list(string), [])
    grafana_ingress_namespaces   = optional(list(string), [])
    grafana_ingress_cidr_blocks  = optional(list(string), [])
  })
  default = {}
}
