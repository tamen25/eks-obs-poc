locals {
  keep_mode = var.source_mode == "keep"

  state_dir = "/var/lib/fluent-bit"

  # Fluent Bit reads the digits after the point as nanoseconds: "0.5" is a 5ns scan loop that
  # used a whole core on kind. Writing all nine digits makes 0.5 mean half a second.
  refresh_interval = format("%d.%09d", floor(var.tuning.refresh_interval),
  floor((var.tuning.refresh_interval - floor(var.tuning.refresh_interval)) * 1000000000 + 0.5))

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
      # The agent's allowlist leaves only these and log, so the line is sent exactly as written.
      remove_keys     = join(", ", concat(local.meta_keys, ["stream"]))
      drop_single_key = "raw"
      line_format     = "key_value"
      retry_limit     = "no_limits"
      workers         = var.tuning.output_workers
      "net.keepalive" = "on"
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
      refresh_interval = local.refresh_interval
      read_from_head   = "true"
      # Kubernetes removing a pod's log looks like a rotation to Fluent Bit; this is how long
      # a deleted log is still read. The default (5s) lost lines whenever the agent was behind.
      rotate_wait     = var.tuning.rotate_wait
      mem_buf_limit   = var.tuning.mem_buf_limit
      skip_long_lines = "on"
      "storage.type"  = "filesystem"
    },
    # Both modes take pod identity from the file path when the API cannot supply it.
    { path_key = "filepath" },
    length(local.exclude_paths) == 0 ? {} : { exclude_path = join(",", local.exclude_paths) },
  )

  # The kubernetes filter asks the API for pod metadata when it first reads a file. A pod
  # deleted before that (force delete, a pod that lives a second) has none, and its lines
  # would reach Loki with no namespace or container (seen in the kind e2e test). The file
  # name carries pod, namespace and container, so those are parsed first and used wherever
  # the API had nothing: modify's rename and add only act when the target key is absent.
  container_filters = [
    {
      name         = "parser"
      match        = "kube.*"
      key_name     = "filepath"
      parser       = "container_path"
      reserve_data = "on"
    },
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
    { name = "modify", match = "kube.*", rename = "file_namespace k8s_namespace_name" },
    { name = "modify", match = "kube.*", rename = "file_pod k8s_pod_name" },
    { name = "modify", match = "kube.*", rename = "file_container k8s_container_name" },
    { name = "modify", match = "kube.*", add = "k8s_host $${NODE_NAME}" },
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

  container_tag = local.keep_mode ? "keep" : "kube.*"

  # journald: kubelet, the container runtime and the kernel. The systemd input replaces the
  # tag's * with the unit name; kernel entries have no unit and are labelled unit="kernel".
  journal_input = {
    name                = "systemd"
    tag                 = "node.*"
    path                = var.node_logs.journal_path
    db                  = "${local.state_dir}/journal.db"
    systemd_filter      = concat([for u in var.node_logs.units : "_SYSTEMD_UNIT=${u}"], var.node_logs.kernel ? ["_TRANSPORT=kernel"] : [])
    systemd_filter_type = "or"
    strip_underscores   = "on"
    lowercase           = "on"
    mem_buf_limit       = var.tuning.mem_buf_limit
    "storage.type"      = "filesystem"
  }
  journal_filters = [
    { name = "modify", match = "node.*", add = "systemd_unit kernel" },
    { name = "record_modifier", match = "node.*", allowlist_key = ["message", "systemd_unit", "priority"] },
    { name = "record_modifier", match = "node.*", record = "node $${NODE_NAME}" },
  ]
  node_output = merge(local.loki_output, {
    match               = "node.*"
    labels              = "cluster=$${CLUSTER_NAME}, job=node, unit=$systemd_unit${local.static_labels}"
    structured_metadata = "node=$node, priority=$priority"
    remove_keys         = "systemd_unit, node, priority"
  })
  node_outputs = [for o in [local.node_output] : { for k, v in o : k => tostring(v) } if var.node_logs.enabled]

  # The journal is read in place; it needs its own mount unless it is under /var/log.
  journal_mounted = !var.node_logs.enabled || startswith(var.node_logs.journal_path, "/var/log/")

  # Last filter in either mode. The CRI parser leaves a time key and the kubernetes filter adds
  # pod_ip; any key besides log that reached the output would turn the line into
  # time="..." log="<line>" pod_ip="...", which breaks | json in LogQL (seen in the kind e2e
  # test on every pod). Listing what stays, instead of what goes, also covers keys a later
  # Fluent Bit version adds.
  allowlist_filter = {
    name          = "record_modifier"
    match         = local.container_tag
    allowlist_key = concat(["log", "stream"], local.meta_keys)
  }

  # Conditionals between objects of different shapes do not type-check in Terraform, so the
  # alternatives are normalised to map(string) / list(map(string)) first.
  agent_outputs = var.via_aggregator ? [merge(local.forward_output_strings, { match = "*" })] : concat(
    [merge(local.loki_output_strings, { match = local.container_tag })],
    local.node_outputs,
  )
  agent_filters = concat(
    local.keep_mode ? local.keep_filters_strings : local.container_filters_strings,
    [local.allowlist_filter],
    [for f in local.journal_filters : f if var.node_logs.enabled],
  )

  loki_output_strings       = { for k, v in local.loki_output : k => tostring(v) }
  forward_output_strings    = { for k, v in local.forward_output : k => tostring(v) }
  keep_filters_strings      = [for f in local.keep_filters : { for k, v in f : k => tostring(v) }]
  container_filters_strings = [for f in local.container_filters : { for k, v in f : k => tostring(v) }]

  keep_parsers = [{
    name   = "keep_path"
    format = "regex"
    regex  = "^/var/log/keep/(?<k8s_namespace_name>[^_]+)_(?<k8s_pod_name>[^_]+)_(?<k8s_pod_id>[^/]+)/(?<k8s_container_name>[^/]+)/"
  }]
  # /var/log/containers/<pod>_<namespace>_<container>-<64 hex container id>.log
  container_parsers = [{
    name   = "container_path"
    format = "regex"
    regex  = "^/var/log/containers/(?<file_pod>[^_]+)_(?<file_namespace>[^_]+)_(?<file_container>.+)-[0-9a-f]{64}\\.log$"
  }]

  agent_config = merge(
    {
      service = {
        flush        = var.tuning.flush
        log_level    = var.tuning.log_level
        http_server  = "on"
        http_listen  = "0.0.0.0"
        http_port    = 2020
        health_check = "on"
        # On SIGTERM (drain, spot reclaim, rollout) keep flushing for this long instead of the
        # 5s default; anything still unsent stays in storage.path for the next start.
        grace                       = 30
        "storage.path"              = "${local.state_dir}/storage"
        "storage.sync"              = "normal"
        "storage.backlog.mem_limit" = "50M"
        "storage.metrics"           = "on"
      }
      pipeline = {
        inputs  = concat([local.tail_input], [for i in [local.journal_input] : i if var.node_logs.enabled])
        filters = local.agent_filters
        outputs = local.agent_outputs
      }
    },
    { parsers = local.keep_mode ? local.keep_parsers : local.container_parsers },
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
      grace          = 30
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
      # Forwarded records keep the agent's tag, so container and node logs still get their own
      # labels here.
      outputs = concat(
        [merge(local.loki_output_strings, { match = local.container_tag })],
        local.node_outputs,
      )
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
    # Longer than the service grace period above, so the kubelet does not kill the flush.
    terminationGracePeriodSeconds = 60

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
      [for p in [var.node_logs.journal_path] : { name = "journal", hostPath = { path = p, type = "Directory" } } if !local.journal_mounted],
      local.ca_volume,
    )
    daemonSetVolumeMounts = concat(
      [
        { name = "varlog", mountPath = "/var/log", readOnly = true },
        { name = "state", mountPath = local.state_dir },
      ],
      [for p in [var.node_logs.journal_path] : { name = "journal", mountPath = p, readOnly = true } if !local.journal_mounted],
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
