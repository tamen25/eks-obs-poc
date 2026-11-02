# Every optional component on, so static scanners (checkov) see all resources.
# Not meant for deployment: the values are placeholders.
cluster_name = "test-cluster"
aws_region   = "us-east-1"
environment  = "dev"

aws_identity_mode = "pod_identity"

loki = {
  retention_period = "17520h"
  storage = {
    backend                  = "s3"
    access_log_bucket        = "central-s3-access-logs"
    allowed_vpc_endpoint_ids = ["vpce-0123456789abcdef0"]
    tiering                  = { archive = { enabled = true, after_days = 365 } }
  }
}

fluent_bit = {
  aggregator = { enabled = true }
  log_keeper = {
    enabled = true
    image   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/log-keeper:1.0.0"
  }
}

network_policies = {
  monitoring_namespaces = ["monitoring"]
}

grafana = {
  enabled          = true
  cloudwatch_audit = true
}
