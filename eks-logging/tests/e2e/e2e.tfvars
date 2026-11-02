# Small enough for Docker Desktop. Everything not listed keeps the stack's defaults, including
# internal TLS, NetworkPolicies, hot/warm tiering and every eviction setting.
cluster_name = "e2e-cluster"
aws_region   = "us-east-1"
environment  = "e2e"

# kind's local-path provisioner instead of the EBS CSI driver.
storage_class = {
  create = false
  name   = "standard"
}

loki = {
  monolithic_replicas = 1
  persistence_size    = "2Gi"
  resources           = { requests_cpu = "100m", requests_memory = "256Mi", limits_memory = "1Gi" }
  caches              = { chunks_memory_mb = 128, results_memory_mb = 64 }
  gateway             = { replicas = 1 }
  storage = {
    backend       = "s3"
    force_destroy = true
    kms           = { deletion_window_in_days = 7 }
  }
  # moto takes static keys and has a throwaway certificate; on EKS this is IRSA and the
  # AWS S3 endpoint with a public certificate.
  extra_values_yaml = <<-EOT
    loki:
      storage:
        s3:
          endpoint: eks-logging-moto:5000
          s3ForcePathStyle: true
          accessKeyId: test
          secretAccessKey: test
          http_config:
            insecure_skip_verify: true
  EOT
}

# kind nodes keep a volatile journal; EKS AL2023 nodes keep it in /var/log/journal.
fluent_bit = {
  node_logs = { journal_path = "/run/log/journal" }
}

grafana = {
  enabled          = true
  persistence_size = "1Gi"
  resources        = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } }
}
