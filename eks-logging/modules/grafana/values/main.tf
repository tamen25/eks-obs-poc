locals {
  tls_to_loki         = var.loki_datasource.tls_ca_secret != ""
  ca_mount_path       = "/etc/grafana/loki-ca"
  password_mount_path = "/etc/grafana/loki-credentials"
  ingress_has_tls     = var.ingress.enabled && (var.ingress.tls_secret != "" || startswith(var.root_url, "https://"))

  loki_datasource = {
    name          = "Loki"
    type          = "loki"
    uid           = "loki"
    access        = "proxy"
    url           = var.loki_datasource.url
    isDefault     = true
    basicAuth     = true
    basicAuthUser = var.loki_datasource.user
    editable      = false
    jsonData = {
      maxLines          = 5000
      timeout           = 120
      tlsAuthWithCACert = local.tls_to_loki
    }
    # Grafana reads these files when it loads the provisioning config, so no secret is written
    # into the chart's ConfigMap (the chart refuses that anyway: assertNoLeakedSecrets) and none
    # sits in the process environment.
    secureJsonData = merge(
      { basicAuthPassword = "$__file{${local.password_mount_path}/password}" },
      local.tls_to_loki ? { tlsCACert = "$__file{${local.ca_mount_path}/ca.crt}" } : {},
    )
  }

  cloudwatch_datasource = [for enabled in [var.cloudwatch.enabled] : {
    name     = "CloudWatch"
    type     = "cloudwatch"
    uid      = "cloudwatch"
    access   = "proxy"
    editable = false
    # The pod's own credentials: IRSA or Pod Identity, set up by the root module.
    jsonData = {
      authType      = "default"
      defaultRegion = var.cloudwatch.region
    }
  } if enabled]

  base_ini = {
    analytics = {
      reporting_enabled        = false
      check_for_updates        = false
      check_for_plugin_updates = false
    }
    security = {
      disable_gravatar               = true
      cookie_secure                  = local.ingress_has_tls
      cookie_samesite                = "lax"
      strict_transport_security      = local.ingress_has_tls
      allow_embedding                = false
      content_security_policy        = true
      disable_initial_admin_creation = false
    }
    users            = { allow_sign_up = false, allow_org_create = false }
    "auth.anonymous" = { enabled = false }
    "auth.basic"     = { enabled = true }
    snapshots        = { external_enabled = false }
    log              = { mode = "console", level = "info" }
    server           = { root_url = var.root_url }
    plugins          = { preinstall_auto_update = "false" }
  }

  # Merge per section, so overriding one key (say security.cookie_samesite) keeps the rest.
  ini = {
    for section in setunion(keys(local.base_ini), keys(var.ini_overrides)) :
    section => merge(lookup(local.base_ini, section, {}), lookup(var.ini_overrides, section, {}))
  }

  values = merge(
    {
      replicas = var.replicas

      global = var.image_registry == "" ? {} : { imageRegistry = var.image_registry }

      testFramework = { enabled = false }

      # Runs as root to chown the volume; fsGroup on the pod already sets ownership, and the
      # namespace enforces the restricted Pod Security level.
      initChownData = { enabled = false }

      admin = {
        existingSecret = var.admin_secret
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }

      # Dashboards come from a mounted ConfigMap, not the API sidecar, so Grafana needs no
      # Kubernetes API token. IRSA / Pod Identity mount their own token when CloudWatch is on.
      serviceAccount = {
        create                       = true
        annotations                  = var.service_account_annotations
        automountServiceAccountToken = false
      }
      automountServiceAccountToken = false

      # The image runs as UID 472; changing it breaks file ownership inside the image.
      annotations = {
        "checkov.io/skip1" = "CKV_K8S_40=Grafana image runs as UID 472; other UIDs break ownership of its data paths"
        "checkov.io/skip2" = "CKV_K8S_35=The chart passes the break-glass admin login from admin.existingSecret as environment variables"
      }

      persistence = {
        enabled          = var.persistence.enabled
        type             = "pvc"
        size             = var.persistence.size
        storageClassName = var.persistence.storage_class == "" ? null : var.persistence.storage_class
      }

      # Service port = container port, which the VPC CNI network policy agent requires.
      service = { type = "ClusterIP", port = 3000, targetPort = 3000 }

      ingress = {
        enabled          = var.ingress.enabled
        ingressClassName = var.ingress.class_name
        annotations      = var.ingress.annotations
        hosts            = [var.ingress.host]
        path             = "/"
        pathType         = "Prefix"
        tls              = var.ingress.tls_secret == "" ? [] : [{ secretName = var.ingress.tls_secret, hosts = [var.ingress.host] }]
      }

      "grafana.ini" = local.ini

      extraSecretMounts = concat(
        [{
          name        = "loki-credentials"
          secretName  = var.loki_datasource.password_secret
          defaultMode = 288 # 0440
          mountPath   = local.password_mount_path
          readOnly    = true
        }],
        [for secret in [var.loki_datasource.tls_ca_secret] : {
          name        = "loki-ca"
          secretName  = secret
          defaultMode = 292 # 0444
          mountPath   = local.ca_mount_path
          readOnly    = true
        } if secret != ""],
      )

      datasources = {
        "datasources.yaml" = {
          apiVersion  = 1
          datasources = concat([local.loki_datasource], local.cloudwatch_datasource)
        }
      }

      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1
          providers = [{
            name            = "logging"
            orgId           = 1
            folder          = "Logging"
            type            = "file"
            disableDeletion = true
            editable        = false
            allowUiUpdates  = false
            options         = { path = "/var/lib/grafana/dashboards/logging" }
          }]
        }
      }

      dashboardsConfigMaps = { logging = var.dashboards_config_map }

      resources    = var.resources
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
    },
    var.image_tag == "" ? {} : { image = { tag = var.image_tag } },
  )
}
