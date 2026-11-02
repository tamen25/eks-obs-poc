mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-loki" }
  }
}

variables {
  name              = "test-loki"
  cluster_name      = "test-cluster"
  cluster_arn       = "arn:aws:eks:us-east-1:123456789012:cluster/test-cluster"
  mode              = "irsa"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABC"
  oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/ABC"
  namespace         = "loki"
  service_account   = "loki"
  policy_json       = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
}

run "irsa_trust_is_bound_to_one_service_account" {
  command = apply

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals == {
      "oidc.eks.us-east-1.amazonaws.com/id/ABC:sub" = "system:serviceaccount:loki:loki"
      "oidc.eks.us-east-1.amazonaws.com/id/ABC:aud" = "sts.amazonaws.com"
    }
    error_message = "IRSA trust must pin both sub (namespace/service account) and aud."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.this) == 0
    error_message = "No Pod Identity association in irsa mode."
  }

  assert {
    condition     = output.service_account_annotations["eks.amazonaws.com/role-arn"] == aws_iam_role.this.arn
    error_message = "The service account needs the role annotation in irsa mode."
  }
}

run "pod_identity_trust_uses_session_tags" {
  command = apply

  variables {
    mode = "pod_identity"
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals == {
      "aws:RequestTag/eks-cluster-arn"            = "arn:aws:eks:us-east-1:123456789012:cluster/test-cluster"
      "aws:RequestTag/kubernetes-namespace"       = "loki"
      "aws:RequestTag/kubernetes-service-account" = "loki"
    }
    error_message = "Pod Identity trust must be limited to this cluster, namespace and service account."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.this) == 1 && length(output.service_account_annotations) == 0
    error_message = "Pod Identity mode creates an association and no annotation."
  }
}

run "irsa_needs_oidc_details" {
  command = plan

  variables {
    oidc_provider_arn = null
  }

  expect_failures = [aws_iam_role.this]
}
