variables {
  replicas       = 1
  image_registry = ""
  image_tag      = ""
  admin_secret   = "grafana-admin"
  persistence    = { enabled = true, size = "10Gi", storage_class = "logging-gp3-encrypted" }
  ingress        = { enabled = false, class_name = "alb", host = "", annotations = {}, tls_secret = "" }
  root_url       = ""
  ini_overrides  = {}
  loki_datasource = {
    url             = "https://loki-gateway.loki.svc.cluster.local:443", user = "test-cluster"
    password_secret = "grafana-loki-credentials", tls_ca_secret = "grafana-loki-ca"
  }
  cloudwatch                  = { enabled = false, region = "us-east-1" }
  service_account_annotations = {}
  dashboards_config_map       = "grafana-logging-dashboards"
  resources                   = {}
  node_selector               = {}
  tolerations                 = []
  extra_values_yaml           = ""
}

run "hardened_defaults" {
  command = plan

  assert {
    condition = (
      !yamldecode(output.values[0])["grafana.ini"].analytics.reporting_enabled &&
      !yamldecode(output.values[0])["grafana.ini"]["auth.anonymous"].enabled &&
      !yamldecode(output.values[0])["grafana.ini"].users.allow_sign_up
    )
    error_message = "Telemetry, anonymous access and sign-up must be off."
  }

  assert {
    condition     = !yamldecode(output.values[0]).initChownData.enabled
    error_message = "The root chown init container must stay off (restricted namespace)."
  }

  assert {
    condition = (
      yamldecode(output.values[0]).datasources["datasources.yaml"].datasources[0].secureJsonData.basicAuthPassword == "$__file{/etc/grafana/loki-credentials/password}" &&
      strcontains(yamldecode(output.values[0]).datasources["datasources.yaml"].datasources[0].secureJsonData.tlsCACert, "$__file{")
    )
    error_message = "Datasource secrets come from the environment and a mounted file, not from values."
  }

  assert {
    condition     = length(yamldecode(output.values[0]).datasources["datasources.yaml"].datasources) == 1
    error_message = "No CloudWatch datasource unless enabled."
  }
}

run "ini_overrides_merge_per_section" {
  command = plan

  variables {
    ini_overrides = { security = { cookie_samesite = "strict" } }
  }

  assert {
    condition = (
      yamldecode(output.values[0])["grafana.ini"].security.cookie_samesite == "strict" &&
      yamldecode(output.values[0])["grafana.ini"].security.disable_gravatar
    )
    error_message = "Overriding one key keeps the rest of its section."
  }
}

run "cloudwatch_datasource" {
  command = plan

  variables {
    cloudwatch = { enabled = true, region = "eu-west-1" }
  }

  assert {
    condition     = yamldecode(output.values[0]).datasources["datasources.yaml"].datasources[1].jsonData.defaultRegion == "eu-west-1"
    error_message = "The CloudWatch datasource uses the pod's credentials in the cluster region."
  }
}
