locals {
  keep_mode = var.source_mode == "keep"

  state_dir = "/var/lib/fluent-bit"

  # Every record leaves the agent with the same k8s_* fields whichever source it came from,
  # so the Loki output (here or in the aggregator) does not care how it was collected.
  meta_keys = ["k8s_namespace_name", "k8s_pod_name", "k8s_pod_id", "k8s_container_name", "k8s_host"]

  exclude_paths = local.keep_mode ? [
    for ns in var.tuning.exclude_namespaces : "/var/log/keep/${ns}_*/*/*.log"
    ] : [
    for ns in var.tuning.exclude_namespaces : "/var/log/containers/*_${ns}_*.log"
  ]

  static_labels = join("", [for k, v in var.tuning.static_labels : ", ${k}=${v}"])

  # Without the internal CA, Fluent Bit verifies against the image's system CA bundle.
  tls_settings = merge(
    { "tls" = var.loki.tls ? "on" : "off" },
    var.loki.tls ? { "tls.verify" = var.loki.tls_verify ? "on" : "off" } : {},
    var.loki.tls && var.loki.internal_ca ? { "tls.ca_file" = "${var.ca_mount_path}/ca.crt" } : {},
  )
  mount_ca = var.loki.internal_ca || var.via_aggregator

  # Shared by the agent and the aggregator, whichever one talks to Loki.
  loki_output = merge(
    {
      name        = "loki"
      host        = var.loki.host
      port        = var.loki.port
      uri         = var.loki.uri
      http_user   = "$${LOKI_USERNAME}"
      http_passwd = "$${LOKI_PASSWORD}"
      # Few, low-cardinality labels. Pod name, UID and node go to structured metadata: still
      # queryable (| pod="x"), without one stream per pod. The UID tells apart a StatefulSet
      # pod from the one that replaced it under the same name.
      labels              = "cluster=$${CLUSTER_NAME}, namespace=$k8s_namespace_name, container=$k8s_container_name${local.static_labels}"
      structured_metadata = "pod=$k8s_pod_name, pod_uid=$k8s_pod_id, node=$k8s_host, stream=$stream"
      remove_keys         = join(", ", concat(local.meta_keys, ["kubernetes", "k8s_container_image", "k8s_docker_id", "k8s_container_hash", "stream", "_p", "filepath"]))
      drop_single_key     = "raw"
      line_format         = "key_value"
      retry_limit         = "no_limits"
      workers             = var.tuning.output_workers
      "net.keepalive"     = "on"
    },
    var.loki.tenant_id == "" ? {} : { tenant_id = var.loki.tenant_id },
    local.tls_settings,
  )

  forward_output = {
    name       = "forward"
    host       = var.aggregator.host
    port       = var.aggregator.port
    shared_key = "$${FORWARD_SHARED_KEY}"
    # The agent keeps a chunk until the aggregator confirms it has stored it.
    require_ack_response = "true"
    retry_limit          = "no_limits"
    "tls"                = "on"
    "tls.verify"         = "on"
    "tls.ca_file"        = "${var.ca_mount_path}/ca.crt"
  }

  tail_input = merge(
    {
      name               = "tail"
      tag                = local.keep_mode ? "keep" : "kube.*"
      path               = local.keep_mode ? "/var/log/keep/*/*/*.log" : "/var/log/containers/*.log"
      "multiline.parser" = "cri"
      db                 = "${local.state_dir}/tail.db"
      "db.locking"       = "true"
      # refresh_interval only controls how fast new files are found; lines in files already
      # tailed are read on each write. Pods that live and die between two scans are missed
      # unless log-keeper holds their files (FINDINGS.md, rounds 3 and 4).
      refresh_interval = var.tuning.refresh_interval
      read_from_head   = "true"
      # Kubernetes removing a pod's log looks like a rotation to Fluent Bit; this is how long
      # a deleted log is still read. The default (5s) lost lines whenever the agent was behind.
      rotate_wait     = var.tuning.rotate_wait
      mem_buf_limit   = var.tuning.mem_buf_limit
      skip_long_lines = "on"
      "storage.type"  = "filesystem"
    },
    local.keep_mode ? { path_key = "filepath" } : {},
    length(local.exclude_paths) == 0 ? {} : { exclude_path = join(",", local.exclude_paths) },
  )

  container_filters = [
    {
      name            = "kubernetes"
      match           = "kube.*"
      kube_tag_prefix = "kube.var.log.containers."
      merge_log       = "off"
      labels          = "off"
      annotations     = "off"
      # Pods may not opt themselves out of collection through annotations.
      "k8s-logging.exclude" = "off"
      "k8s-logging.parser"  = "off"
      buffer_size           = var.tuning.kube_buffer_size
    },
    {
      name         = "nest"
      match        = "kube.*"
      operation    = "lift"
      nested_under = "kubernetes"
      add_prefix   = "k8s_"
    },
  ]

  keep_filters = [
    {
      name         = "parser"
      match        = "keep"
      key_name     = "filepath"
      parser       = "keep_path"
      reserve_data = "on"
    },
    {
      name   = "record_modifier"
      match  = "keep"
      record = "k8s_host $${NODE_NAME}"
    },
  ]

  # Conditionals between objects of different shapes do not type-check in Terraform, so the
  # alternatives are normalised to map(string) / list(map(string)) first.
  agent_output  = var.via_aggregator ? local.forward_output_strings : local.loki_output_strings
  agent_filters = local.keep_mode ? local.keep_filters_strings : local.container_filters_strings

  loki_output_strings       = { for k, v in local.loki_output : k => tostring(v) }
  forward_output_strings    = { for k, v in local.forward_output : k => tostring(v) }
  keep_filters_strings      = [for f in local.keep_filters : { for k, v in f : k => tostring(v) }]
  container_filters_strings = [for f in local.container_filters : { for k, v in f : k => tostring(v) }]

  keep_parsers = [for p in [{
    name   = "keep_path"
    format = "regex"
    regex  = "^/var/log/keep/(?<k8s_namespace_name>[^_]+)_(?<k8s_pod_name>[^_]+)_(?<k8s_pod_id>[^/]+)/(?<k8s_container_name>[^/]+)/"
  }] : p if local.keep_mode]

  agent_config = merge(
    {
      service = {
        flush                       = var.tuning.flush
        log_level                   = var.tuning.log_level
        http_server                 = "on"
        http_listen                 = "0.0.0.0"
        http_port                   = 2020
        health_check                = "on"
        "storage.path"              = "${local.state_dir}/storage"
        "storage.sync"              = "normal"
        "storage.backlog.mem_limit" = "50M"
        "storage.metrics"           = "on"
      }
      pipeline = {
        inputs  = [local.tail_input]
        filters = local.agent_filters
        outputs = [merge(local.agent_output, { match = local.keep_mode ? "keep" : "kube.*" })]
      }
    },
    { for k, v in { parsers = local.keep_parsers } : k => v if local.keep_mode },
  )

  events_output = merge(local.loki_output, {
    match               = "k8s_events"
    labels              = "cluster=$${CLUSTER_NAME}, job=kubernetes-events, namespace=$involvedObject['namespace'], reason=$reason, kind=$involvedObject['kind']${local.static_labels}"
    structured_metadata = "object=$involvedObject['name']"
    remove_keys         = "metadata"
    drop_single_key     = "off"
    line_format         = "json"
  })

  events_config = {
    service = {
      flush        = var.tuning.flush
      log_level    = var.tuning.log_level
      http_server  = "on"
      http_listen  = "0.0.0.0"
      http_port    = 2020
      health_check = "on"
    }
    pipeline = {
      inputs = [{
        name         = "kubernetes_events"
        tag          = "k8s_events"
        kube_url     = "https://kubernetes.default.svc"
        interval_sec = 5
        db           = "/tmp/events.db"
      }]
      outputs = [local.events_output]
    }
  }

  aggregator_config = {
    service = {
      flush          = var.tuning.flush
      log_level      = var.tuning.log_level
      http_server    = "on"
      http_listen    = "0.0.0.0"
      http_port      = 2020
      health_check   = "on"
      "storage.path" = "/var/lib/fluent-bit-aggregator/storage"
      # fsync each chunk: what the aggregator acknowledged must survive its own crash.
      "storage.sync"    = "full"
      "storage.metrics" = "on"
    }
    pipeline = {
      inputs = [{
        name           = "forward"
        listen         = "0.0.0.0"
        port           = var.aggregator.port
        shared_key     = "$${FORWARD_SHARED_KEY}"
        "storage.type" = "filesystem"
        "tls"          = "on"
        "tls.verify"   = "off" # server side: clients authenticate with the shared key
        "tls.crt_file" = "/fluent-bit/tls/tls.crt"
        "tls.key_file" = "/fluent-bit/tls/tls.key"
      }]
      outputs = [merge(local.loki_output, { match = "*" })]
    }
  }

  agent_config_yaml      = yamlencode(local.agent_config)
  events_config_yaml     = yamlencode(local.events_config)
  aggregator_config_yaml = yamlencode(local.aggregator_config)

  image = {
    repository = var.chart.image_repository
    tag        = var.chart.image_tag
  }

  credential_env = [
    { name = "CLUSTER_NAME", value = var.tuning.static_labels["cluster"] },
    { name = "LOKI_USERNAME", valueFrom = { secretKeyRef = { name = var.chart.credentials_secret, key = "username" } } },
    { name = "LOKI_PASSWORD", valueFrom = { secretKeyRef = { name = var.chart.credentials_secret, key = "password" } } },
  ]

  restricted_container = {
    runAsNonRoot             = true
    runAsUser                = 65534
    runAsGroup               = 65534
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    capabilities             = { drop = ["ALL"] }
    seccompProfile           = { type = "RuntimeDefault" }
  }

  ca_volume = local.mount_ca ? [{ name = "internal-ca", secret = { secretName = var.chart.ca_secret, defaultMode = 292 } }] : [] # 0444
  ca_mount  = local.mount_ca ? [{ name = "internal-ca", mountPath = var.ca_mount_path, readOnly = true }] : []

  # Exceptions to static checks that the agent cannot avoid, recorded on the workload itself so
  # whoever reads it in the cluster sees why.
  agent_check_exceptions = merge(
    {
      "checkov.io/skip1" = "CKV_K8S_23=Reads root-owned node log files (0640); all capabilities dropped, read-only root filesystem"
      "checkov.io/skip2" = "CKV_K8S_40=Runs as UID 0 for the same reason"
      "checkov.io/skip3" = "CKV_K8S_35=Fluent Bit reads output credentials from environment variables only"
    },
    local.keep_mode ? {} : { "checkov.io/skip4" = "CKV_K8S_38=The kubernetes filter queries the API for pod metadata" },
  )

  agent_values = {
    kind  = "DaemonSet"
    image = local.image

    testFramework = { enabled = false }
    # Keep mode takes labels from file paths and never calls the Kubernetes API.
    serviceAccount = { create = true, automountServiceAccountToken = !local.keep_mode }
    rbac           = { create = true, nodeAccess = false, eventsAccess = false }
    annotations    = local.agent_check_exceptions

    # The node's log files are root-owned (0640), so the agent runs as UID 0. Every capability
    # is dropped and the root filesystem is read-only; only the state directory is writable.
    podSecurityContext = { seccompProfile = { type = "RuntimeDefault" } }
    securityContext = merge(
      {
        runAsUser                = 0
        runAsGroup               = 0
        runAsNonRoot             = false
        privileged               = false
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        capabilities             = { drop = ["ALL"] }
        seccompProfile           = { type = "RuntimeDefault" }
      },
      var.chart.selinux_type == "" ? {} : { seLinuxOptions = { type = var.chart.selinux_type } },
    )

    # Node-pressure eviction takes lower-priority pods first; the shipper has to outlive the
    # workloads it is collecting from. It also tolerates every taint, NoExecute included,
    # so it is not evicted in the same second as the pods whose logs it is reading.
    priorityClassName = "system-node-critical"
    tolerations       = [{ operator = "Exists" }]

    resources = var.chart.agent_resources

    existingConfigMap = var.chart.agent_config_map
    command           = ["/fluent-bit/bin/fluent-bit"]
    args              = ["--workdir=/fluent-bit/etc", "--config=/fluent-bit/etc/conf/fluent-bit.yaml"]
    # The chart's own checksum/config hashes its built-in ConfigMap, which existingConfigMap
    # replaces, so it never changes. This one rolls the pods when the real config changes.
    podAnnotations = { "checksum/pipeline-config" = sha256(local.agent_config_yaml) }

    env = concat(
      local.credential_env,
      [{ name = "NODE_NAME", valueFrom = { fieldRef = { fieldPath = "spec.nodeName" } } }],
      var.via_aggregator ? [{ name = "FORWARD_SHARED_KEY", valueFrom = { secretKeyRef = { name = var.chart.forward_key_secret, key = "shared-key" } } }] : [],
    )

    daemonSetVolumes = concat(
      [
        { name = "varlog", hostPath = { path = "/var/log", type = "Directory" } },
        { name = "state", hostPath = { path = local.state_dir, type = "DirectoryOrCreate" } },
      ],
      local.ca_volume,
    )
    daemonSetVolumeMounts = concat(
      [
        { name = "varlog", mountPath = "/var/log", readOnly = true },
        { name = "state", mountPath = local.state_dir },
      ],
      local.ca_mount,
    )

    # A restart drops open handles on logs that are already deleted (FINDINGS.md round 4);
    # roll one node at a time.
    updateStrategy = { type = "RollingUpdate", rollingUpdate = { maxUnavailable = 1 } }

    serviceMonitor = { enabled = var.chart.service_monitor }
  }

  events_values = {
    kind         = "Deployment"
    replicaCount = 1
    image        = local.image

    testFramework  = { enabled = false }
    serviceAccount = { create = true }
    rbac           = { create = true, nodeAccess = false, eventsAccess = true }
    annotations = {
      "checkov.io/skip1" = "CKV_K8S_35=Fluent Bit reads output credentials from environment variables only"
      "checkov.io/skip2" = "CKV_K8S_38=The kubernetes_events input watches events through the API"
    }

    podSecurityContext = { runAsNonRoot = true, runAsUser = 65534, runAsGroup = 65534, fsGroup = 65534, seccompProfile = { type = "RuntimeDefault" } }
    securityContext    = local.restricted_container

    priorityClassName = "system-cluster-critical"
    resources         = var.chart.events_resources

    existingConfigMap = var.chart.events_config_map
    command           = ["/fluent-bit/bin/fluent-bit"]
    args              = ["--workdir=/fluent-bit/etc", "--config=/fluent-bit/etc/conf/fluent-bit.yaml"]
    podAnnotations    = { "checksum/pipeline-config" = sha256(local.events_config_yaml) }

    env                   = local.credential_env
    extraVolumes          = concat([{ name = "tmp", emptyDir = { sizeLimit = "64Mi" } }], local.ca_volume)
    extraVolumeMounts     = concat([{ name = "tmp", mountPath = "/tmp" }], local.ca_mount)
    daemonSetVolumes      = []
    daemonSetVolumeMounts = []

    serviceMonitor = { enabled = var.chart.service_monitor }
  }
}
