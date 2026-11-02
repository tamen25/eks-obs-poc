variables {
  source_mode    = "containers"
  via_aggregator = false
  loki = {
    host = "loki-gateway.loki.svc.cluster.local", port = 8080, uri = "/loki/api/v1/push"
    tls  = true, tls_verify = true, tenant_id = "", internal_ca = true
  }
  ca_mount_path = "/fluent-bit/tls-ca"
  aggregator    = { host = "fluent-bit-aggregator.logging.svc.cluster.local", port = 24224 }
  tuning = {
    flush     = 1, refresh_interval = 0.5, rotate_wait = 300, mem_buf_limit = "50MB", kube_buffer_size = "512k"
    log_level = "info", exclude_namespaces = [], static_labels = { cluster = "test-cluster" }, output_workers = 2
  }
  node_logs = { enabled = true, journal_path = "/var/log/journal", units = ["kubelet.service", "containerd.service"], kernel = true }
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
    condition     = one([for f in yamldecode(output.agent_config_yaml).pipeline.filters : f["k8s-logging.exclude"] if f.name == "kubernetes"]) == "off"
    error_message = "Containers mode enriches through the API and pods cannot opt out of collection."
  }

  # A pod deleted before the agent's API lookup (force delete, one-second pods) still gets its
  # namespace, pod and container from the file name; the e2e test on kind lost them without it.
  assert {
    condition = (
      yamldecode(output.agent_config_yaml).pipeline.inputs[0].path_key == "filepath" &&
      yamldecode(output.agent_config_yaml).pipeline.filters[0].parser == "container_path" &&
      [for f in yamldecode(output.agent_config_yaml).pipeline.filters : f.name][1] == "kubernetes" &&
      toset([for f in yamldecode(output.agent_config_yaml).pipeline.filters : f.rename if f.name == "modify" && can(f.rename)]) == toset([
        "file_namespace k8s_namespace_name", "file_pod k8s_pod_name", "file_container k8s_container_name",
      ]) &&
      can(regex(yamldecode(output.agent_config_yaml).parsers[0].regex, "/var/log/containers/web-7d9f_shop_app-${join("", [for i in range(64) : "a"])}.log"))
    )
    error_message = "Pod identity must fall back to the file name, after the API lookup had its chance."
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

# Without the allowlist the CRI parser's time key and the kubernetes filter's pod_ip reached
# Loki, and every line was stored as time="..." log="<line>" pod_ip="..." (kind e2e test).
run "lines_reach_loki_exactly_as_written" {
  command = plan

  assert {
    condition = (
      reverse([for f in yamldecode(output.agent_config_yaml).pipeline.filters : f if f.match == "kube.*"])[0].name == "record_modifier" &&
      toset(reverse([for f in yamldecode(output.agent_config_yaml).pipeline.filters : f if f.match == "kube.*"])[0].allowlist_key) == toset([
        "log", "stream", "k8s_namespace_name", "k8s_pod_name", "k8s_pod_id", "k8s_container_name", "k8s_host",
      ])
    )
    error_message = "The last container filter must keep only log, stream and the k8s_* keys the output uses."
  }

  assert {
    condition = (
      toset(split(", ", yamldecode(output.agent_config_yaml).pipeline.outputs[0].remove_keys)) == toset([
        "stream", "k8s_namespace_name", "k8s_pod_name", "k8s_pod_id", "k8s_container_name", "k8s_host",
      ]) &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].drop_single_key == "raw"
    )
    error_message = "The output must remove every allowlisted key but log, so log is sent raw."
  }
}

run "node_journal_is_collected" {
  command = plan

  assert {
    condition = (
      yamldecode(output.agent_config_yaml).pipeline.inputs[1].name == "systemd" &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[1].path == "/var/log/journal" &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[1].systemd_filter == [
        "_SYSTEMD_UNIT=kubelet.service", "_SYSTEMD_UNIT=containerd.service", "_TRANSPORT=kernel",
      ] &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[1].db == "/var/lib/fluent-bit/journal.db"
    )
    error_message = "kubelet, containerd and kernel entries are read from the journal, with a position database."
  }

  assert {
    condition = (
      yamldecode(output.agent_config_yaml).pipeline.outputs[1].match == "node.*" &&
      strcontains(yamldecode(output.agent_config_yaml).pipeline.outputs[1].labels, "job=node, unit=$systemd_unit") &&
      strcontains(yamldecode(output.agent_config_yaml).pipeline.outputs[1].structured_metadata, "node=$node") &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].match == "kube.*"
    )
    error_message = "Node logs get their own output and labels; container logs keep theirs."
  }

  assert {
    condition     = !contains([for v in yamldecode(output.agent_values_yaml).daemonSetVolumes : v.name], "journal")
    error_message = "A journal under /var/log is read through the existing /var/log mount."
  }
}

run "journal_outside_var_log_is_mounted_read_only" {
  command = plan

  variables {
    node_logs = { enabled = true, journal_path = "/run/log/journal", units = ["kubelet.service"], kernel = false }
  }

  assert {
    condition = (
      one([for v in yamldecode(output.agent_values_yaml).daemonSetVolumes : v.hostPath.path if v.name == "journal"]) == "/run/log/journal" &&
      one([for m in yamldecode(output.agent_values_yaml).daemonSetVolumeMounts : m.readOnly if m.name == "journal"])
    )
    error_message = "A journal outside /var/log gets its own read-only hostPath mount."
  }
}

run "node_logs_can_be_turned_off" {
  command = plan

  variables {
    node_logs = { enabled = false, journal_path = "/var/log/journal", units = [], kernel = false }
  }

  assert {
    condition = (
      length(yamldecode(output.agent_config_yaml).pipeline.inputs) == 1 &&
      length(yamldecode(output.agent_config_yaml).pipeline.outputs) == 1 &&
      !anytrue([for f in yamldecode(output.agent_config_yaml).pipeline.filters : f.match == "node.*"])
    )
    error_message = "With node_logs off the agent only tails container logs."
  }
}

run "agent_survives_the_evictions_it_records" {
  command = plan

  # Each setting closes one eviction gap measured in the lab (FINDINGS.md): the agent must not
  # be evicted before its victims, must read deleted files long enough to finish them, must
  # find new files fast enough for pods that live seconds, and must flush on shutdown.
  assert {
    condition = (
      yamldecode(output.agent_values_yaml).priorityClassName == "system-node-critical" &&
      yamldecode(output.agent_values_yaml).tolerations[0].operator == "Exists" &&
      yamldecode(output.agent_values_yaml).terminationGracePeriodSeconds > yamldecode(output.agent_config_yaml).service.grace &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[0].rotate_wait >= 300 &&
      tonumber(yamldecode(output.agent_config_yaml).pipeline.inputs[0].refresh_interval) <= 1 &&
      yamldecode(output.agent_config_yaml).pipeline.inputs[0]["storage.type"] == "filesystem" &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].retry_limit == "no_limits"
    )
    error_message = "The agent lost one of the eviction protections: priority, tolerations, grace, rotate_wait, refresh_interval, filesystem buffer or unlimited retries."
  }
}

run "sub_second_refresh_interval_means_seconds" {
  command = plan

  # Fluent Bit reads "0.5" as 5 nanoseconds and spins a core scanning; the first attempt of a
  # crash-looping container needs scans faster than its log lives (about 1s), not that.
  assert {
    condition     = yamldecode(output.agent_config_yaml).pipeline.inputs[0].refresh_interval == "0.500000000"
    error_message = "refresh_interval 0.5 must render as 0.500000000 so Fluent Bit reads half a second."
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
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].tls == "on" &&
      yamldecode(output.agent_config_yaml).pipeline.outputs[0].match == "*" &&
      length(yamldecode(output.agent_config_yaml).pipeline.outputs) == 1
    )
    error_message = "Agents forward everything, container and node logs, over TLS and wait for the aggregator's acknowledgement."
  }

  assert {
    condition = (
      [for o in yamldecode(output.aggregator_config_yaml).pipeline.outputs : o.match] == ["kube.*", "node.*"] &&
      strcontains(yamldecode(output.aggregator_config_yaml).pipeline.outputs[1].labels, "job=node")
    )
    error_message = "The aggregator routes forwarded records by their tag to the container or node output."
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
      flush     = 1, refresh_interval = 0.5, rotate_wait = 300, mem_buf_limit = "50MB", kube_buffer_size = "512k"
      log_level = "info", exclude_namespaces = ["kube-system"], static_labels = { cluster = "test-cluster" }, output_workers = 2
    }
  }

  assert {
    condition     = yamldecode(output.agent_config_yaml).pipeline.inputs[0].exclude_path == "/var/log/containers/*_kube-system_*.log"
    error_message = "Excluded namespaces become tail exclude_path patterns."
  }
}
