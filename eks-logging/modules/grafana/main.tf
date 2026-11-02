data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  admin_secret    = "grafana-admin"
  loki_secret     = "grafana-loki-credentials"
  ca_secret       = "grafana-loki-ca"
  dashboards_name = "grafana-logging-dashboards"
  service_account = "grafana"

  audit_log_group_name = "/aws/eks/${var.cluster.name}/cluster"
  audit_log_group_arn  = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.audit_log_group_name}"

  evicted_pods_dashboard = replace(
    file("${path.module}/dashboards/evicted-pods.json"),
    "__AGENTS_NAMESPACE__", var.agents_namespace,
  )

  audit_dashboard = replace(replace(
    file("${path.module}/dashboards/eks-eviction-audit.json"),
    "__AUDIT_LOG_GROUP_ARN__", local.audit_log_group_arn),
    "__AUDIT_LOG_GROUP_NAME__", local.audit_log_group_name,
  )
}

# CloudWatch datasource for the EKS audit log (who drained or evicted a pod): read the
# cluster's control plane log group only.
module "identity" {
  source = "../workload-identity"
  count  = var.settings.cloudwatch_audit ? 1 : 0

  name                     = "${var.name_prefix}-grafana-cw"
  cluster_name             = var.cluster.name
  cluster_arn              = var.cluster.arn
  mode                     = var.identity.mode
  oidc_provider_arn        = var.cluster.oidc_provider_arn
  oidc_issuer_url          = var.cluster.oidc_issuer_url
  namespace                = var.namespace
  service_account          = local.service_account
  permissions_boundary_arn = var.identity.permissions_boundary_arn
  tags                     = var.tags

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "QueryClusterAuditLog"
        Effect = "Allow"
        Action = [
          "logs:StartQuery",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = [local.audit_log_group_arn, "${local.audit_log_group_arn}:*"]
      },
      {
        Sid      = "QueryResultsAndDiscovery"
        Effect   = "Allow"
        Action   = ["logs:GetQueryResults", "logs:StopQuery", "logs:DescribeLogGroups", "logs:GetLogGroupFields"]
        Resource = "*"
      },
    ]
  })
}

# Initial admin login. Wire SSO through settings.ini_overrides (auth.generic_oauth and
# friends) and keep this account for break-glass use.
resource "random_password" "admin" {
  length  = 32
  special = false

  keepers = {
    revision = var.admin_credentials_revision
  }
}

resource "kubernetes_secret_v1" "admin" {
  metadata {
    name      = local.admin_secret
    namespace = var.namespace
  }

  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.admin.result
  }
}

resource "kubernetes_secret_v1" "loki" {
  metadata {
    name      = local.loki_secret
    namespace = var.namespace
  }

  data = {
    password = var.loki_password
  }
}

resource "kubernetes_secret_v1" "ca" {
  count = var.loki.internal_ca ? 1 : 0

  metadata {
    name      = local.ca_secret
    namespace = var.namespace
  }

  data = {
    "ca.crt" = var.loki.ca_cert_pem
  }
}

resource "kubernetes_config_map_v1" "dashboards" {
  metadata {
    name      = local.dashboards_name
    namespace = var.namespace
  }

  data = merge(
    { "evicted-pods.json" = local.evicted_pods_dashboard },
    var.settings.cloudwatch_audit ? { "eks-eviction-audit.json" = local.audit_dashboard } : {},
  )
}

module "values" {
  source = "./values"

  replicas       = var.settings.replicas
  image_registry = var.image_registry
  image_tag      = var.settings.image_tag
  admin_secret   = local.admin_secret
  persistence = {
    enabled       = var.settings.replicas == 1
    size          = var.settings.persistence_size
    storage_class = var.storage_class
  }
  ingress       = var.settings.ingress
  root_url      = var.settings.root_url
  ini_overrides = var.settings.ini_overrides
  loki_datasource = {
    url             = var.loki.url
    user            = var.loki.user
    password_secret = local.loki_secret
    tls_ca_secret   = var.loki.internal_ca ? local.ca_secret : ""
  }
  cloudwatch = {
    enabled = var.settings.cloudwatch_audit
    region  = var.aws_region
  }
  service_account_annotations = var.settings.cloudwatch_audit ? module.identity[0].service_account_annotations : {}
  dashboards_config_map       = local.dashboards_name
  resources                   = var.settings.resources
  node_selector               = var.settings.node_selector
  tolerations                 = var.settings.tolerations
  extra_values_yaml           = var.settings.extra_values_yaml
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = "grafana"
  version    = var.chart.version

  values = module.values.values

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600
  max_history     = 10

  depends_on = [
    kubernetes_secret_v1.admin,
    kubernetes_secret_v1.loki,
    kubernetes_secret_v1.ca,
    kubernetes_config_map_v1.dashboards,
  ]
}

############################################################################################
# NetworkPolicies: Grafana's pods only, so a shared namespace is fine
############################################################################################

locals {
  grafana_pods = {
    "app.kubernetes.io/name"     = "grafana"
    "app.kubernetes.io/instance" = "grafana"
  }
  # An ALB with IP targets connects from addresses in the VPC.
  ingress_cidr_blocks = distinct(concat(
    var.network_policy.ingress_cidr_blocks,
    var.settings.ingress.enabled ? var.network_policy.vpc_cidr_blocks : [],
  ))
  ingress_namespaces = distinct(concat(var.network_policy.ingress_namespaces, var.network_policy.monitoring_namespaces))
}

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "grafana-default-deny-ingress"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = local.grafana_pods
    }
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_http" {
  count = var.network_policy.enabled && length(local.ingress_cidr_blocks) + length(local.ingress_namespaces) > 0 ? 1 : 0

  metadata {
    name      = "grafana-allow-http"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = local.grafana_pods
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "3000"
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = local.ingress_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }

      dynamic "from" {
        for_each = local.ingress_cidr_blocks
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }
  }
}
