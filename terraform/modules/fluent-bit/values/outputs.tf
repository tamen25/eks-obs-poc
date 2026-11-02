output "agent_config_yaml" {
  description = "Fluent Bit YAML config for the node agent."
  value       = local.agent_config_yaml
}

output "events_config_yaml" {
  description = "Fluent Bit YAML config for the Kubernetes event collector."
  value       = local.events_config_yaml
}

output "aggregator_config_yaml" {
  description = "Fluent Bit YAML config for the aggregator."
  value       = local.aggregator_config_yaml
}

output "agent_values_yaml" {
  description = "Helm values for the agent release."
  value       = yamlencode(local.agent_values)
}

output "events_values_yaml" {
  description = "Helm values for the event collector release."
  value       = yamlencode(local.events_values)
}
