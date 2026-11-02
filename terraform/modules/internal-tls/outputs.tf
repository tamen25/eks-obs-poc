output "ca_cert_pem" {
  description = "PEM of the internal CA certificate. Clients use it to verify servers."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "servers" {
  description = "Issued server certificate and key per server name."
  sensitive   = true
  value = {
    for k, _ in var.servers : k => {
      cert_pem        = tls_locally_signed_cert.server[k].cert_pem
      private_key_pem = tls_private_key.server[k].private_key_pem
    }
  }
}
