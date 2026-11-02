# The filesystem storage backend: Loki on its own volume, no S3, KMS key or IAM role. Selected
# with TFVARS=e2e-filesystem.tfvars. Otherwise the same as e2e.tfvars.
cluster_name = "e2e-cluster"
aws_region   = "us-east-1"
environment  = "e2e"

# kind's local-path provisioner instead of the EBS CSI driver.
storage_class = {
  create = false
  name   = "standard"
}

loki = {
  persistence_size = "2Gi"
  resources        = { requests_cpu = "100m", requests_memory = "256Mi", limits_memory = "1Gi" }
  caches           = { chunks_memory_mb = 128, results_memory_mb = 64 }
  gateway          = { replicas = 1 }
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
