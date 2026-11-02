# Logging and tracing POC, all in one cluster

Loki, Tempo, Grafana, Fluent Bit and an OpenTelemetry collector on a local kind cluster.
Nothing outside the cluster: no S3, no AWS account, no load balancer. Loki and Tempo keep
their data on persistent volumes in the cluster.

It is the small version of the target design (a monitoring cluster with Loki, Tempo and
Grafana; Fluent Bit and OpenTelemetry agents in the app clusters), squeezed into one
cluster. The Fluent Bit part is the `eks-logging` stack's own module, unchanged, so log
collection behaves exactly as tested there.

```
 every node                                   observability namespace
 ┌──────────────────────────┐                 ┌──────────────────────────────────────┐
 │ /var/log/containers/*    │                 │  loki-gateway ── Loki (single binary) │
 │ journald (kubelet,       │── Fluent Bit ──▶│  Basic Auth →     volume: chunks,     │
 │ containerd, kernel)      │   (DaemonSet)   │  tenant           index               │
 │ Kubernetes events        │── event         │                                       │
 └──────────────────────────┘   collector ───▶│                                       │
                                              │  OTel collector ── Tempo (single      │
 demo namespace                               │  (+ k8s metadata)  binary) volume:    │
 ┌──────────────────────────┐   OTLP gRPC     │                    traces             │
 │ demo-checkout: traces ───┼────────────────▶│                                       │
 │   and logs with trace_id │                 │  Grafana: Loki + Tempo data sources,  │
 └──────────────────────────┘                 │  linked by trace ID                   │
                                              └──────────────────────────────────────┘
```

## Run it

```bash
./run.sh up       # kind cluster logging-poc, about 1 minute
./run.sh apply    # terraform apply, about 5 minutes
./run.sh check    # the checks below
./run.sh scenarios  # evictions, OOM kill, crash loops, a 300k-line burst..., about 5 minutes
./run.sh grafana  # Grafana on http://127.0.0.1:23030, no login
./run.sh down     # delete the cluster and the Terraform state
```

Needs Docker, kind, kubectl, Terraform 1.9 or later, curl and Python. The demo pod installs
the OpenTelemetry SDK from PyPI on start, so the cluster needs internet access. If `apply`
stops with `no cached repo found`, Helm's index cache in the temp folder was cleared: run
`helm repo update`.

## What is in it

| Component | Chart | What it does here |
|---|---|---|
| Loki | `grafana-community/loki` 20.0.2, single binary | Logs, filesystem storage on a 10 GiB volume, 30-day retention, 7 days for `*-uat` and `*-preprod` namespaces. Multi-tenant: the gateway maps the Basic Auth user to its tenant. Same limits as eks-logging (256 KB lines, truncated rather than dropped) |
| Tempo | `grafana-community/tempo` 3.2.0, single binary | Traces, local storage on a 10 GiB volume, 30-day retention, OTLP in |
| OpenTelemetry collector | `open-telemetry/opentelemetry-collector` 0.176.0 | Receives OTLP from apps on `otel-collector.observability:4317`, adds the pod's namespace, name and node to every span, sends to Tempo |
| Fluent Bit | `fluent/fluent-bit` 0.58.3 via `../eks-logging/modules/fluent-bit` | Every container log on every node, kubelet/containerd/kernel journal, Kubernetes events. See [What gets collected](../eks-logging/README.md#what-gets-collected) |
| Grafana | `grafana-community/grafana` 14.2.0 | No login (anonymous admin). Loki and Tempo data sources. A `trace_id=` field in a log line links to the trace; a span links to its namespace's logs with the same trace ID |
| pod-lifecycle | `alpine/k8s` 1.34.12 via `../eks-logging/modules/pod-lifecycle` | Logs each pod's final state as JSON: eviction reason, disruption condition (Eviction API), OOM kill, exit code, last lines. The "why did it end" panels read it |
| demo-checkout | `python:3.12.10-slim` | A trace per fake order (`checkout` → `db.query`, `payment`), a log line per step with `trace_id` and `span_id`, about 10% failed payments |

To send your own app's traces, point its OpenTelemetry SDK at
`http://otel-collector.observability.svc.cluster.local:4317` (OTLP gRPC) and print the trace
ID in its log lines as `trace_id=<32 hex digits>`.

## Dashboards

Grafana opens on **1 · Overview**; every dashboard has a link bar to the others, and they
all live in the *Logging POC* folder. Each starts with a short note on what it shows, and
every panel has a description (hover the `i`).

| Dashboard | What it answers |
|---|---|
| 1 · Overview (start here) | How much is logged, by which namespaces and containers; error-looking lines; evictions, crash loops and node errors at a glance; latest warning events |
| 2 · Logs explorer | Any container's logs, filtered by namespace, container, stdout/stderr, part of a pod name and free text |
| 3 · Evicted and disrupted pods | How each pod ended (kubelet eviction, Eviction API, OOM, crash loop, preemption, force delete), the matching events, and the pod's last lines after its files are gone |
| 4 · Node logs | kubelet, containerd and kernel: errors, OOM kills, image pull and probe failures, per node |
| 5 · Traces and logs | The demo service's orders and declines, latest and failed traces, and its logs with links to each trace |
| 6 · Test scenarios | For each `./run.sh scenarios` run: lines written vs received per scenario (100% = nothing lost), and why each scenario pod ended |
| 7 · Pipeline health | Which nodes are shipping container logs and journal, log volume per node and namespace, warnings from the agents and the backends |

The dashboards are written by `dashboards/build.py`; edit it and run
`python dashboards/build.py`, then `./run.sh apply`. Changes made in the UI are lost when
Grafana restarts.

## Test scenarios

`./run.sh scenarios` runs each situation once in the `scenarios` namespace. Every line a
scenario writes carries its name, the run ID and its expected line count, so the script (and
dashboard 6) can compare what was written with what reached Loki:

| Scenario | What happens | Lines |
|---|---|---|
| evict-api | evicted through the Eviction API with no grace period, like a drain | 300 |
| evict-kubelet | outgrows its ephemeral-storage limit; the kubelet evicts it | 300 |
| force-delete | deleted with `--grace-period=0 --force` as soon as it runs | 300 |
| short-lived | lives about a second, deleted as soon as it completes | 300 |
| oom-kill | writes its lines, then goes over its 32 Mi memory limit | 100 |
| crashloop | 4 pods exiting straight away; their first 3 attempts | 1,200 |
| burst | 300,000 lines, enough for the kubelet to rotate the log | 300,000 |
| init, sidecar, stdout, stderr | one pod's init container, sidecar, and both streams | 50 each |
| long-100k, long-400k, after-long | a 100 KB line, a 400 KB line (Loki keeps 256 KB) and 50 lines after | 1, 1, 50 |
| bad-image, failing-probe | an image that does not exist and a readiness probe that always fails; they show on the node logs and events panels, not as counted lines | none |

## Try in Explore

Loki: `{namespace="demo"}`; expand a line and click the TraceID link. Tempo, TraceQL:
`{resource.service.name="demo-checkout" && status=error}` for the declined payments.
Other streams: `{job="node"}` (kubelet, containerd, kernel), `{job="kubernetes-events"}`.

## What was verified

`./run.sh check` on kind (Kubernetes 1.34, two nodes):

| Area | What it proved |
|---|---|
| Components | Loki, gateway, Tempo, OTel collector, Grafana, both Fluent Bit agents, the event collector and the demo all Ready from one apply |
| Tenant auth | the gateway returns 401 without credentials and with a wrong password, 200 for the tenant |
| Every container | each container with output on either node (16 in 5 namespaces, system pods included) has a stream in Loki |
| Node logs and events | kubelet and containerd journal from both nodes; Kubernetes events |
| Agent health | 0 records dropped or abandoned |
| Non-prod retention | the `*-uat` / `*-preprod` rule is in Loki's running config |
| Grafana | opens without a login; both data sources pass their health check; the TraceID link URL is provisioned intact |
| Dashboards | all seven load, and all 57 panel queries run through Grafana without an error (`dashboards/check_queries.py`). Event panels must show the object's name on every line. After a scenarios run, every panel has data except preemption (no scenario triggers it) and the kernel panels (kind nodes have no kernel log) |
| Test scenarios | `./run.sh scenarios`: all 14 scenarios delivered 100% of their lines, including 300,000 burst lines through 2 to 3 kubelet rotations, the Eviction API, kubelet and force-delete evictions, the OOM kill and 4 crash loops |
| Kubernetes events | `check` creates a pod in `scenarios`, evicts it and requires the same event count per reason in the API and in Loki. By hand, after a scenarios run, all 10 reasons in that namespace matched too |
| Logs to traces | a trace ID read from a demo log line in Loki opens that trace in Tempo, with all three spans and the pod's namespace added by the collector; TraceQL search finds the service |

The link check was added after the first run showed the TraceID link provisioned as a bare
`$` (an escaping mistake, Grafana expands `$VAR` in provisioning files). It failed against
that deployment and passes since the fix.

## Limits

- **One replica of everything, no object storage.** A lost volume loses the data; Loki and
  Tempo are down while their pod restarts. Fine for a POC, not for production, where the
  `eks-logging` stack (S3, three Loki replicas) applies.
- **No TLS inside the cluster.** The gateway checks the password, but traffic between pods
  is plain HTTP. eks-logging encrypts it.
- **NetworkPolicies only on Fluent Bit** (from its module). Loki, Tempo and Grafana have none.
- **Tempo is single-tenant**, and the OTel collector accepts spans from any pod.
- **Grafana has no login**: anyone who reaches it is an admin. It is only reachable through
  `run.sh grafana` (a port-forward on 127.0.0.1); do not expose it with a Service or Ingress.
- **Grafana keeps no state**: no volume, so dashboards made in the UI are lost when its pod
  restarts. The provisioned dashboards and data sources come back.
- **kind nodes have no kernel log**, so the kernel panels (OOM kills, kernel warnings) stay
  empty here; the OOM kill still shows through the pod-lifecycle record. On EKS the kernel
  stream is collected, but these panels were not seen with real kernel data.
- **kubelet and containerd log errors at journald priority 6**, so node errors are found by
  their text (`E1029 ...`, `level=error`), and probe failures come from `Unhealthy` events.
- **Event lines do not contain the object's namespace, name, kind or reason.** The collector
  moves them to labels and the `object` metadata, so a text search for a pod name only finds
  events whose message mentions it (`Scheduled`, mostly). Select with
  `{job="kubernetes-events", namespace="x"} | object="pod-name"`.
- **Event delivery across restarts was tested by restarting both kind nodes**, not Docker
  Desktop or a real control plane. The collector's container restarted, and all 5 events of a
  pod created afterwards reached Loki.
- **The dashboards were checked by running their queries**, not by looking at each panel:
  a query that runs can still be drawn badly. "Error-looking lines" is a text match on
  error/exception/fatal/panic, not a log level.
- **The 7-day rule for non-prod namespaces** was checked to be in Loki's running config, not
  watched deleting data (that takes 7 days).
