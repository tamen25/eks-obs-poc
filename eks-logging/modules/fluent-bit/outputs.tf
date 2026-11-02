output "source_mode" {
  description = "Where the agent reads logs: containers (/var/log/containers) or keep (/var/log/keep, held by log-keeper)."
  value       = local.source_mode
}

output "aggregator_address" {
  description = "In-cluster address of the aggregator, or null when it is disabled."
  value       = var.aggregator.enabled ? "${local.aggregator_name}.${var.namespace}.svc.cluster.local:${local.aggregator_port}" : null
}

output "agent_config_yaml" {
  description = "Rendered agent pipeline config (for review and tests)."
  value       = module.values.agent_config_yaml
}

output "agent_values_yaml" {
  description = "Rendered agent Helm values (for review and tests)."
  value       = module.values.agent_values_yaml
}

output "events_enabled" {
  description = "Whether the Kubernetes event collector runs."
  value       = length(helm_release.events) == 1
}
