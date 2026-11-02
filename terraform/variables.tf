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
  description = "Environment name, used in resource names and tags (for example dev, staging, prod)."
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

variable "namespaces" {
  description = <<-EOT
    Namespace names. The agents namespace enforces Pod Security "privileged" (the node agent
    and log-keeper read node files through hostPath); Loki and Grafana enforce "restricted".
  EOT
  type = object({
    loki    = optional(string, "loki")
    agents  = optional(string, "logging")
    grafana = optional(string, "grafana")
  })
  default = {}
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

############################################################################################
# AWS identity and object storage for Loki
############################################################################################

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

variable "kms" {
  description = "KMS key for the Loki buckets. create = true makes a key with yearly rotation; otherwise give key_arn."
  type = object({
    create                  = optional(bool, true)
    key_arn                 = optional(string)
    deletion_window_in_days = optional(number, 30)
  })
  default = {}
}

variable "loki_storage" {
  description = "Loki bucket settings."
  type = object({
    force_destroy                      = optional(bool, false)
    versioning                         = optional(bool, true)
    noncurrent_version_expiration_days = optional(number, 7)
    # Days after which S3 deletes any object regardless of Loki. Must exceed Loki retention.
    # null = Loki retention + 30 days.
    expiration_backstop_days = optional(number)
    access_log_bucket        = optional(string)
    allowed_vpc_endpoint_ids = optional(list(string), [])
    admin_principal_arns     = optional(list(string), [])
    # Custom S3 endpoint (for example an interface VPC endpoint DNS name). Empty = AWS default.
    s3_endpoint = optional(string, "")
  })
  default = {}
}

############################################################################################
# Loki
############################################################################################

variable "loki" {
  description = "Loki deployment settings."
  type = object({
    chart_repository = optional(string, "https://grafana-community.github.io/helm-charts")
    chart_version    = optional(string, "20.0.2")
    image_tag        = optional(string, "")

    # Monolithic: one StatefulSet running every component, scaled horizontally; Grafana's
    # guidance is up to a few tens of GB/day. Distributed: one workload per component, for
    # larger volumes. SimpleScalable is deprecated and left out.
    deployment_mode     = optional(string, "Monolithic")
    monolithic_replicas = optional(number, 3)
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
    schema_from      = optional(string, "2025-01-01")
    retention_period = optional(string, "744h")

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

    persistence_size = optional(string, "50Gi")
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
      # Expose the gateway outside the cluster (other clusters pushing, external Grafana).
      # With the AWS Load Balancer Controller: class_name = "alb" plus annotations such as
      # alb.ingress.kubernetes.io/scheme = internal and certificate-arn. When internal TLS is
      # on, also set alb.ingress.kubernetes.io/backend-protocol = HTTPS.
      ingress = optional(object({
        enabled     = optional(bool, false)
        class_name  = optional(string, "alb")
        host        = optional(string, "")
        annotations = optional(map(string), {})
        tls_secret  = optional(string, "")
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
    condition     = var.loki.monolithic_replicas >= 1
    error_message = "loki.monolithic_replicas must be at least 1."
  }

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.loki.schema_from))
    error_message = "loki.schema_from must be a YYYY-MM-DD date."
  }

  validation {
    condition     = can(regex("^\\d+h$", var.loki.retention_period))
    error_message = "loki.retention_period must be in hours, for example 744h."
  }

  validation {
    condition     = var.loki.tenant_id == null || can(regex("^[a-zA-Z0-9_.-]{1,64}$", var.loki.tenant_id))
    error_message = "loki.tenant_id may only contain letters, digits, '_', '.' and '-' (max 64)."
  }

  validation {
    condition     = !var.loki.gateway.ingress.enabled || var.loki.gateway.ingress.host != ""
    error_message = "loki.gateway.ingress.host is required when the ingress is enabled."
  }
}

############################################################################################
# Collection: Fluent Bit agents, event collector, aggregator, log-keeper, pod-lifecycle
############################################################################################

variable "fluent_bit" {
  description = "Node agent and event collector settings."
  type = object({
    chart_repository = optional(string, "https://fluent.github.io/helm-charts")
    chart_version    = optional(string, "0.58.3")
    image = optional(object({
      repository = optional(string, "cr.fluentbit.io/fluent/fluent-bit")
      tag        = optional(string, "5.1.3")
    }), {})

    # How often new log files are discovered. Lines in files already tailed are read on each
    # write regardless. <= 2s catches every kubelet-evicted pod (its files stay about 3s);
    # costs about 1 mCPU more than 60s at 1,000 files (FINDINGS.md round 3).
    refresh_interval = optional(number, 2)
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
    events_enabled = optional(bool, true)
    events_resources = optional(any, {
      requests = { cpu = "20m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    })

    service_monitor = optional(bool, false)

    # Push somewhere other than the Loki this stack deploys (another cluster's gateway, a
    # central Loki). The password is read from loki_endpoint_password.
    loki_endpoint_override = optional(object({
      host       = string
      port       = optional(number, 443)
      uri        = optional(string, "/loki/api/v1/push")
      tls        = optional(bool, true)
      tls_verify = optional(bool, true)
      tenant_id  = optional(string, "")
      username   = string
    }))
  })
  default = {}

  validation {
    condition     = var.fluent_bit.refresh_interval >= 1 && var.fluent_bit.rotate_wait >= 5
    error_message = "fluent_bit.refresh_interval must be >= 1 and rotate_wait >= 5."
  }

  validation {
    condition     = var.fluent_bit.image.tag != "" && var.fluent_bit.image.tag != "latest"
    error_message = "fluent_bit.image.tag must be a pinned version."
  }
}

variable "loki_endpoint_password" {
  description = "Password for fluent_bit.loki_endpoint_override. Ignored without an override."
  type        = string
  default     = ""
  sensitive   = true
}

variable "aggregator" {
  description = <<-EOT
    Aggregator tier. Agents forward to it (TLS, shared key, acknowledgements) and it pushes to
    Loki, so a Loki slowdown builds backlog on its volumes instead of on the nodes.
  EOT
  type = object({
    enabled      = optional(bool, false)
    replicas     = optional(number, 2)
    storage_size = optional(string, "20Gi")
    resources = optional(object({
      requests = optional(map(string), { cpu = "100m", memory = "256Mi" })
      limits   = optional(map(string), { memory = "1Gi" })
    }), {})
  })
  default = {}

  validation {
    condition     = !var.aggregator.enabled || var.internal_tls.enabled
    error_message = "The aggregator's forward listener always uses TLS: enable internal_tls with it."
  }
}

variable "log_keeper" {
  description = <<-EOT
    log-keeper hard-links every new container log so it outlives the kubelet deleting it
    (eviction, force delete, rotation) and shipper restarts. The agent then reads the kept
    copies. Needs an image built from images/log-keeper.
  EOT
  type = object({
    enabled       = optional(bool, false)
    image         = optional(string, "")
    ttl_minutes   = optional(number, 10)
    max_orphan_mb = optional(number, 1024)
    resources = optional(object({
      requests = optional(map(string), { cpu = "10m", memory = "16Mi" })
      limits   = optional(map(string), { memory = "64Mi" })
    }), {})
  })
  default = {}

  validation {
    condition     = !var.log_keeper.enabled || var.log_keeper.image != ""
    error_message = "log_keeper.image is required when log_keeper is enabled (build images/log-keeper)."
  }
}

variable "pod_lifecycle" {
  description = "Watcher that logs pod terminal states (eviction reason, disruption condition, last lines)."
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

############################################################################################
# Grafana
############################################################################################

variable "grafana" {
  description = "Grafana settings. enabled = false skips it (use loki outputs to wire an existing Grafana)."
  type = object({
    enabled          = optional(bool, true)
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
}

############################################################################################
# Network security
############################################################################################

variable "internal_tls" {
  description = <<-EOT
    TLS for in-cluster log traffic (agents/Grafana -> Loki gateway, agents -> aggregator),
    using a private CA this stack generates. Private keys end up in Terraform state.
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
    NetworkPolicies for all three namespaces: default deny on ingress, then only the paths the
    stack needs (agents and Grafana to the Loki gateway, agents to the aggregator, metrics,
    probes, the Grafana ingress). Only enforced when the CNI supports it: on the VPC CNI, enable
    network policy in the add-on configuration first.
  EOT
  type = object({
    enabled                   = optional(bool, false)
    extra_client_namespaces   = optional(list(string), [])
    monitoring_namespaces     = optional(list(string), [])
    extra_ingress_cidr_blocks = optional(list(string), [])
    # Node subnets, for kubelet probes on CNIs that apply policies to them.
    node_cidr_blocks = optional(list(string), [])
    # Who may reach Grafana: an ingress controller's namespace, or the ALB subnets when the
    # AWS Load Balancer Controller uses IP targets. Empty = nothing outside the namespace.
    grafana_ingress_namespaces  = optional(list(string), [])
    grafana_ingress_cidr_blocks = optional(list(string), [])
  })
  default = {}
}
