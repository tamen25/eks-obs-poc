provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  # Short-lived tokens from `aws eks get-token` on every run: no static Kubernetes credentials
  # in state or on disk. The caller needs an EKS access entry (or aws-auth mapping) with
  # cluster-admin rights, since this creates namespaces, cluster roles and webhooks via charts.
  kube_exec_args = concat(
    ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region, "--output", "json"],
    var.kubernetes_auth_role_arn == null ? [] : ["--role-arn", var.kubernetes_auth_role_arn],
  )
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.kube_exec_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.kube_exec_args
    }
  }
}
