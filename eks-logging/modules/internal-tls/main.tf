# A small private CA for traffic that stays inside the cluster (agents -> aggregator ->
# Loki gateway, Grafana -> Loki gateway). Private keys live in Terraform state, which is why
# the root module requires an encrypted remote backend. Swap this module for cert-manager or
# AWS Private CA if either is already run in the account.

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = var.ca_validity_hours

  subject {
    common_name  = var.common_name
    organization = "logging-internal"
  }

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}

resource "tls_private_key" "server" {
  for_each = var.servers

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "server" {
  for_each = var.servers

  private_key_pem = tls_private_key.server[each.key].private_key_pem
  dns_names       = each.value.dns_names

  subject {
    common_name  = each.value.dns_names[0]
    organization = "logging-internal"
  }
}

resource "tls_locally_signed_cert" "server" {
  for_each = var.servers

  cert_request_pem      = tls_cert_request.server[each.key].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = var.server_validity_hours
  early_renewal_hours   = var.early_renewal_hours

  allowed_uses = ["digital_signature", "key_encipherment", "server_auth"]
}
