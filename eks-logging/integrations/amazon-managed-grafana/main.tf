# Adds the eks-logging Loki as a datasource in an existing Amazon Managed Grafana workspace,
# with the evicted-pods dashboard. A separate root module: it needs a workspace token, which
# the main stack has no reason to hold.
#
# Networking is a prerequisite, not done here: the workspace needs a VPC connection to the
# cluster's VPC (or one routed to it), and the Loki gateway must be exposed through
# loki.gateway.ingress (ALB) or a LoadBalancer service (NLB) in the main stack.

provider "aws" {
  region = var.aws_region
}

data "aws_grafana_workspace" "this" {
  workspace_id = var.workspace_id
}

provider "grafana" {
  url  = "https://${data.aws_grafana_workspace.this.endpoint}"
  auth = var.grafana_token
}

locals {
  private_ca = var.loki.ca_cert_pem != ""

  evicted_pods_dashboard = replace(replace(
    file("${path.module}/../../modules/grafana/dashboards/evicted-pods.json"),
    "__AGENTS_NAMESPACE__", var.dashboards.agents_namespace),
    "\"uid\": \"loki\"", "\"uid\": \"${var.datasource.uid}\"",
  )
}

resource "grafana_data_source" "loki" {
  type = "loki"
  name = var.datasource.name
  uid  = var.datasource.uid
  url  = var.loki.url

  basic_auth_enabled  = true
  basic_auth_username = var.loki.user

  json_data_encoded = jsonencode(merge(
    { maxLines = 5000, timeout = 300 },
    local.private_ca ? { tlsAuthWithCACert = true } : {},
  ))

  # Stored encrypted by Grafana; never returned by its API.
  secure_json_data_encoded = jsonencode(merge(
    { basicAuthPassword = var.loki_password },
    local.private_ca ? { tlsCACert = var.loki.ca_cert_pem } : {},
  ))
}

resource "grafana_folder" "logging" {
  count = var.dashboards.enabled ? 1 : 0

  title = var.dashboards.folder
}

resource "grafana_dashboard" "evicted_pods" {
  count = var.dashboards.enabled ? 1 : 0

  folder      = grafana_folder.logging[0].uid
  config_json = local.evicted_pods_dashboard
  overwrite   = true

  depends_on = [grafana_data_source.loki]
}
