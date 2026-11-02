variable "agents_namespace" {
  description = "Namespace of the node agents, event collector, aggregator and watchers."
  type        = string
}

variable "grafana_namespace" {
  description = "Namespace of Grafana, or empty when Grafana is not deployed."
  type        = string
}

variable "aggregator_enabled" {
  description = "Allow agents to reach the aggregator's forward port."
  type        = bool
}

variable "monitoring_namespaces" {
  description = "Namespaces allowed to scrape metrics (Fluent Bit 2020, Grafana 3000)."
  type        = list(string)
}

variable "node_cidr_blocks" {
  description = "Node subnets, for kubelet probes on CNIs that apply policies to them."
  type        = list(string)
}

variable "grafana_ingress_namespaces" {
  description = "Namespaces allowed to reach Grafana (for example an ingress controller's)."
  type        = list(string)
}

variable "grafana_ingress_cidr_blocks" {
  description = "Address ranges allowed to reach Grafana (for example the ALB subnets with IP targets)."
  type        = list(string)
}
