locals {
  oidc_host = var.oidc_issuer_url == null ? "" : replace(var.oidc_issuer_url, "https://", "")

  irsa_trust = {
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account}"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  }

  pod_identity_trust = {
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        # Pod Identity sets these session tags on every request: only this cluster,
        # namespace and service account may assume the role.
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = var.cluster_arn
          "aws:RequestTag/kubernetes-namespace"       = var.namespace
          "aws:RequestTag/kubernetes-service-account" = var.service_account
        }
      }
    }]
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = "${var.namespace}/${var.service_account} on EKS cluster ${var.cluster_name}"
  assume_role_policy   = var.mode == "irsa" ? jsonencode(local.irsa_trust) : jsonencode(local.pod_identity_trust)
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = 3600
  tags                 = var.tags

  lifecycle {
    precondition {
      condition     = var.mode != "irsa" || (var.oidc_provider_arn != null && var.oidc_issuer_url != null)
      error_message = "irsa mode needs oidc_provider_arn and oidc_issuer_url."
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-access"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_eks_pod_identity_association" "this" {
  count = var.mode == "pod_identity" ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn
  tags            = var.tags
}
