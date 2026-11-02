output "datasource_uid" {
  description = "UID of the Loki datasource in the workspace."
  value       = grafana_data_source.loki.uid
}

output "dashboard_url" {
  description = "URL of the evicted-pods dashboard, or null when dashboards are disabled."
  value       = var.dashboards.enabled ? grafana_dashboard.evicted_pods[0].url : null
}
