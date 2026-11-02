output "values" {
  description = "Helm values as YAML documents, in the order Helm should merge them (later wins)."
  sensitive   = true
  value       = compact([yamlencode(local.values), var.extra_values_yaml])
}

output "gateway_service" {
  description = "Name and port of the gateway Service the chart creates."
  value = {
    name   = "loki-gateway"
    port   = local.gateway_port
    scheme = var.gateway.tls_enabled ? "https" : "http"
  }
}
