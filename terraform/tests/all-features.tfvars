# Every optional component on, so static scanners (checkov) see all resources.
# Not meant for deployment: the values are placeholders.
cluster_name = "test-cluster"
aws_region   = "us-east-1"
environment  = "dev"

aws_identity_mode = "pod_identity"

aggregator = {
  enabled = true
}

log_keeper = {
  enabled = true
  image   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/log-keeper:1.0.0"
}

network_policies = {
  enabled          = true
  node_cidr_blocks = ["10.0.0.0/16"]
}

grafana = {
  cloudwatch_audit = true
}

loki_storage = {
  access_log_bucket        = "central-s3-access-logs"
  allowed_vpc_endpoint_ids = ["vpce-0123456789abcdef0"]
}
