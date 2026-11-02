output "keep_path" {
  description = "Directory on each node where kept logs live; point the agent's source_mode at \"keep\" to read it."
  value       = "/var/log/keep"
}
