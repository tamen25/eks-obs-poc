variable "common_name" {
  description = "Common name of the internal CA."
  type        = string
}

variable "servers" {
  description = "Server certificates to issue, keyed by a short name. Each entry lists the DNS names the certificate covers."
  type = map(object({
    dns_names = list(string)
  }))
}

variable "ca_validity_hours" {
  description = "Lifetime of the CA certificate."
  type        = number
  default     = 43800 # 5 years
}

variable "server_validity_hours" {
  description = "Lifetime of server certificates."
  type        = number
  default     = 8760 # 1 year
}

variable "early_renewal_hours" {
  description = "Terraform replaces a server certificate on the first apply within this many hours of its expiry. Apply at least this often."
  type        = number
  default     = 720 # 30 days
}
