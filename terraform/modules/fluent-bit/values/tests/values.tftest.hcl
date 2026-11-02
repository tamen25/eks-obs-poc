variables {
  source_mode    = "containers"
  via_aggregator = false
  loki = {
    host = "loki-gateway.loki.svc.cluster.local", port = 443, uri = "/loki/api/v1/push"
    tls  = true, tls_verify = true, tenant_id = "", internal_ca = true
  }
  ca_mount_path = "/fluent-bit/tls-ca"
  aggregator    = { host = "fluent-bit-aggregator.logging.svc.cluster.local", port = 24224 }
  tuning = {
    flush     = 1, refresh_interval = 2, rotate_wait = 300, mem_buf_limit = "50MB", kube_buffer_size = "512k"
    log_level = "info", exclude_namespaces = [], static_labels = { cluster = "test-cluster" }, output_workers = 2
  }
  chart = {
    image_repository   = "cr.fluentbit.io/fluent/fluent-bit", image_tag = "5.1.3"
    agent_config_map   = "fluent-bit-agent-config", events_config_map = "fluent-bit-events-config"
    credentials_secret = "loki-credentials", ca_secret = "logging-internal-ca", forward_key_secret = "fluent-bit-forward-key"
    agent_resources    = {}, events_resources = {}, service_monitor = false, selinux_type = ""
  }
}

run "containers_mode_keeps_lab_settings" {
  command = plan

  assert {
    condition = (
      yamldecode(output.agent_config_yaml).pipeline.inputs[0].rotate_wait == 300 &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[0]["storage.type"] == "filesystem" &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[0].read_from_head == "true" &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[0].path == "/var/log/containers/*.log"
    )
    error_message = "The tail input must keep rotate_wait, filesystem buffering and read_from_head."
  }

  assert {
    condition     = yamldecode(output.agent_config_yaml).pipeline.filters[0].name == "kubernetes" && yamldecode(output.agent_config_yaml).pipeline.filters[0]["k8s-logging.exclude"] == "off"
    error_message = "Containers mode enriches through the API and pods cannot opt out of collection."
  }

  assert {
    condition = (
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].name == "loki" &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].retry_limit == "no_limits" &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0]["tls.ca_file"] == "/fluent-bit/tls-ca/ca.crt"
    )
    error_message = "The agent pushes to Loki with unlimited retries, verified against the internal CA."
  }

  assert {
    condition     = strcontains(yamldecode(output.agent_config_yaml).pipeline.outputs[0].structured_metadata, "pod_uid=")
    error_message = "Pod UID travels as structured metadata (StatefulSet name reuse)."
  }

  assert {
    condition     = !strcontains(yamldecode(output.agent_config_yaml).pipeline.outputs[0].labels, "pod=")
    error_message = "Pod name must not be a label (one stream per pod)."
  }

  assert {
    condition = (
      yamldecode(output.agent_values_yaml).securityContext.readOnlyRootFilesystem &&
      yamldecode(output.agent_values_yaml).securityContext.capabilities.drop == ["ALL"] &&
      !yamldecode(output.agent_values_yaml).securityContext.allowPrivilegeEscalation &&
      yamldecode(output.agent_values_yaml).priorityClassName == "system-node-critical" &&
      yamldecode(output.agent_values_yaml).tolerations == [{ operator = "Exists" }]
    )
    error_message = "The agent is hardened, node-critical and tolerates every taint."
  }

  assert {
    condition     = !yamldecode(output.events_values_yaml).securityContext.allowPrivilegeEscalation && yamldecode(output.events_values_yaml).securityContext.runAsNonRoot
    error_message = "The event collector runs non-root."
  }

  # The chart already sets checksum/config; reusing that key produced a duplicate YAML key that
  # Helm rejects (caught by kubeconform on the rendered manifests).
  assert {
    condition     = !contains(keys(yamldecode(output.agent_values_yaml).podAnnotations), "checksum/config")
    error_message = "Pod annotations must not reuse the chart's checksum/config key."
  }
}

run "keep_mode_reads_kept_files_with_path_labels" {
  command = plan

  variables {
    source_mode = "keep"
  }

  assert {
    condition = (
      yamldecode(output.agent_config_yaml).pipeline.inputs[0].path == "/var/log/keep/*/*/*.log" &&
      yamldecode(output.agent_config_yaml).parsers[0].name == "keep_path" &&
      !anytrue([for f in yamldecode(output.agent_config_yaml).pipeline.filters : f.name == "kubernetes"])
    )
    error_message = "Keep mode tails /var/log/keep and takes labels from the path, without API lookups."
  }
}

run "aggregator_mode_forwards_with_acks" {
  command = plan

  variables {
    via_aggregator = true
  }

  assert {
    condition = (
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].name == "forward" &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].require_ack_response == "true" &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].tls == "on"
    )
    error_message = "Agents forward over TLS and wait for the aggregator's acknowledgement."
  }

  assert {
    condition     = yamldecode(output.aggregator_config_yaml).service["storage.sync"] == "full"
    error_message = "The aggregator must fsync what it acknowledges."
  }
}

run "external_endpoint_uses_system_ca" {
  command = plan

  variables {
    loki = {
      host = "loki.example.com", port = 443, uri = "/loki/api/v1/push"
      tls  = true, tls_verify = true, tenant_id = "team-a", internal_ca = false
    }
  }

  assert {
    condition = (
      !contains(keys(yamldecode(output.agent_config_yaml).pipeline.outputs[0]), "tls.ca_file") &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].tenant_id == "team-a"
    )
    error_message = "An external endpoint is verified with the system CA bundle and gets the tenant header."
  }
}

run "excluded_namespaces" {
  command = plan

  variables {
    tuning = {
      flush     = 1, refresh_interval = 2, rotate_wait = 300, mem_buf_limit = "50MB", kube_buffer_size = "512k"
      log_level = "info", exclude_namespaces = ["kube-system"], static_labels = { cluster = "test-cluster" }, output_workers = 2
    }
  }

  assert {
    condition     = yamldecode(output.agent_config_yaml).pipeline.inputs[0].exclude_path == "/var/log/containers/*_kube-system_*.log"
    error_message = "Excluded namespaces become tail exclude_path patterns."
  }
}
