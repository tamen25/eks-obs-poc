resource "kubernetes_namespace_v1" "this" {
  for_each = var.namespaces

  metadata {
    name = each.value.name
    labels = merge(var.labels, each.value.extra_labels, {
      "pod-security.kubernetes.io/enforce" = each.value.pod_security
      # Warn and audit against "restricted" everywhere, so drift shows up in kubectl output
      # and the audit log even where enforcement has to be looser.
      "pod-security.kubernetes.io/warn"  = "restricted"
      "pod-security.kubernetes.io/audit" = "restricted"
    })
  }
}

resource "kubernetes_storage_class_v1" "this" {
  count = var.storage_class.create ? 1 : 0

  metadata {
    name = var.storage_class.name
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = merge(
    {
      type      = "gp3"
      encrypted = "true"
    },
    var.storage_class.kms_key_arn == null ? {} : { kmsKeyId = var.storage_class.kms_key_arn },
  )
}
