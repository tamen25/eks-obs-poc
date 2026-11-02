# Offline: AWS and Grafana are mocked. Checks what would be sent to the workspace, not that
# the workspace can reach Loki.

mock_provider "aws" {
  mock_data "aws_grafana_workspace" {
    defaults = { endpoint = "g-0123456789.grafana-workspace.us-east-1.amazonaws.com" }
  }
}

mock_provider "grafana" {}

variables {
  aws_region    = "us-east-1"
  workspace_id  = "g-0123456789"
  grafana_token = "not-a-real-token"
  loki = {
    url         = "https://loki.internal.example.com:8080"
    user        = "test-cluster"
    ca_cert_pem = "-----BEGIN CERTIFICATE-----\nMIIBmock\n-----END CERTIFICATE-----\n"
  }
  loki_password = "not-a-real-password"
}

run "private_ca_and_password_go_in_secure_json" {
  command = apply

  # Secrets must only travel in secure_json_data (encrypted, write-only in Grafana), never in
  # json_data, which any viewer of the datasource can read.
  assert {
    condition = (
      jsondecode(grafana_data_source.loki.secure_json_data_encoded).basicAuthPassword == "not-a-real-password" &&
      startswith(jsondecode(grafana_data_source.loki.secure_json_data_encoded).tlsCACert, "-----BEGIN CERTIFICATE-----") &&
      jsondecode(grafana_data_source.loki.json_data_encoded).tlsAuthWithCACert &&
      !strcontains(grafana_data_source.loki.json_data_encoded, "not-a-real-password")
    )
    error_message = "Password and CA belong in secure_json_data; json_data only flags CA verification."
  }

  assert {
    condition     = grafana_data_source.loki.basic_auth_enabled && grafana_data_source.loki.basic_auth_username == "test-cluster"
    error_message = "The datasource authenticates as the tenant (the gateway maps the user to the tenant)."
  }
}

run "dashboard_points_at_this_datasource" {
  command = apply

  assert {
    condition = (
      strcontains(grafana_dashboard.evicted_pods[0].config_json, "\"uid\": \"eks-logs-loki\"") &&
      !strcontains(grafana_dashboard.evicted_pods[0].config_json, "\"uid\": \"loki\"") &&
      !strcontains(grafana_dashboard.evicted_pods[0].config_json, "__AGENTS_NAMESPACE__")
    )
    error_message = "The dashboard must query the datasource created here and the real agents namespace."
  }
}

run "public_ca_needs_no_tls_settings" {
  command = apply

  variables {
    loki = { url = "https://loki.internal.example.com", user = "test-cluster" }
  }

  assert {
    condition     = !can(jsondecode(grafana_data_source.loki.secure_json_data_encoded).tlsCACert)
    error_message = "Behind an ALB with an ACM certificate there is no private CA to send."
  }
}

run "rejects_plain_http" {
  command = plan

  variables {
    loki = { url = "http://loki.internal.example.com", user = "test-cluster" }
  }

  expect_failures = [var.loki]
}
