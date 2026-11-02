output "namespaces" {
  description = "Created namespace names by role."
  value       = { for k, ns in kubernetes_namespace_v1.this : k => ns.metadata[0].name }
}

output "storage_class_name" {
  description = "StorageClass to use for persistent volumes."
  value       = var.storage_class.name
}
