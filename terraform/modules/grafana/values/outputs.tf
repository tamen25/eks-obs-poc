output "values" {
  description = "Helm values as YAML documents, in merge order (later wins)."
  value       = compact([yamlencode(local.values), var.extra_values_yaml])
}
