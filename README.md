# EKS logging and tracing POC

| Folder | What it is | Status |
|---|---|---|
| [eks-logging](eks-logging/README.md) | Terraform for Fluent Bit, Loki and Grafana on EKS. Start with [DEPLOYMENT.md](eks-logging/DEPLOYMENT.md) | tested on kind with an AWS emulator, **not yet applied to real EKS** |
| [poc-local](poc-local/README.md) | Logs and traces in one local kind cluster (adds Tempo and an OpenTelemetry collector), with dashboards and test scenarios | run on kind |
| [terraform](terraform/README.md) | The first version of the EKS stack, kept unchanged for reference | superseded by `eks-logging` |
| This page, `lab.py`, `manifests`, `results` | The eviction lab below, whose measurements shaped the stack's settings | run on kind |

# Evicted pod logs lab: Fluent Bit and Promtail to Loki

A kind cluster that ships pod logs to Loki with Fluent Bit and Promtail side by
side, plus a harness that evicts pods in different ways and measures, line by
line, what each shipper delivered. Findings are in [FINDINGS.md](FINDINGS.md).

## What runs where

```
kind cluster "evict-lab" (kindest/node v1.34.0)
  control-plane
    fluent-bit-events   Deployment  Kubernetes events -> Loki (job=k8s-events)
    pod-lifecycle       Deployment  pod terminal states as JSON on stdout
    kube-apiserver      audit log of pods/eviction + pod deletes (optional, audit/)
  worker (lab/role=workload, test pods run here)
  every node
    fluent-bit          DaemonSet   tuned tail of /var/log/containers  shipper=fluent-bit
    fluent-bit-defaults DaemonSet   stock tail settings (control group) shipper=fluent-bit-defaults
    promtail            DaemonSet   kubernetes_sd pod targets           shipper=promtail-sd
    promtail-static     DaemonSet   glob /var/log/pods, no API          shipper=promtail-static
    alloy               DaemonSet   glob /var/log/pods (Promtail's successor) shipper=alloy
    otel-filelog        DaemonSet   OTel Collector file_log -> Loki /otlp  service_name=otel-filelog
    vector              DaemonSet   kubernetes_logs source              shipper=vector
    log-keeper          DaemonSet   hard-links new pod logs into /var/log/keep (inotify)
    fluent-bit-keep     DaemonSet   ships only /var/log/keep, refresh 10s  shipper=fb-keep
    fluent-bit-agg-agent DaemonSet  forwards (with acks) to the aggregator
  control-plane
    fluent-bit-aggregator Deployment forward -> disk buffer -> Loki       shipper=fb-via-agg
  worker only
    fluent-bit-proof    DaemonSet   test instrument: refresh 10s, 512KB buffer  shipper=fb-proof

docker container "evict-lgtm" on the kind network (grafana/otel-lgtm 0.34.0)
  Loki 3.7.8    http://127.0.0.1:23100   (pods reach it as http://evict-lgtm:3100)
  Grafana 13.2  http://127.0.0.1:23000   dashboard: /d/evicted-pods
```

Every stream carries a `shipper` label, so the same pod's logs can be compared
across shippers in one query. The exception is the OTel Collector: it pushes
OTLP, so its streams are `{service_name="otel-filelog"}`, with the
`k8s_namespace_name`, `k8s_pod_name` and `k8s_container_name` labels.

## Bring it up

Requires Docker Desktop, kind, kubectl and Python 3.10+. Host ports 23000 and
23100 must be free (3000-3362 are taken or reserved by Windows on this machine).

```bash
kind create cluster --config kind-config.yaml

docker run -d --name evict-lgtm --network kind \
  -p 127.0.0.1:23000:3000 -p 127.0.0.1:23100:3100 \
  -e LOKI_EXTRA_ARGS="-distributor.ingestion-rate-limit-mb=256 -distributor.ingestion-burst-size-mb=512 -ingester.per-stream-rate-limit=256MB -ingester.per-stream-rate-limit-burst=512MB" \
  grafana/otel-lgtm:0.34.0

kubectl --context kind-evict-lab apply -f manifests/
python audit/enable-audit.py          # optional: API server audit log (restarts the API server)

jq '{dashboard: ., overwrite: true}' dashboards/evicted-pods.json \
  | curl -s -X POST -H 'Content-Type: application/json' -d @- http://127.0.0.1:23000/api/dashboards/db
```

The raised Loki limits keep 429s out of the measurements. With Loki's default
4 MB/s per tenant, the log-burst scenarios also measure rate limiting.

## Run experiments

```bash
python lab.py list                                   # scenarios and what they test
python lab.py run api-eviction                       # one run, prints a report
python lab.py run api-eviction-fast log-burst-api --repeat 5   # repeated, with a summary
python lab.py rescore results/*.json                 # recompute saved runs from Loki
python bench/refresh_cost.py --files 100 1000        # CPU cost of Fluent Bit refresh_interval
python bench/read_latency.py                         # discovery delay vs read latency per refresh_interval
```

Some edge-case scenarios change the lab while they run and put it back after:
`paused-drain-api` and `rotation-paused-drain` freeze Loki with `docker pause`;
`node-memory-pressure`, `node-disk-pressure` and `rotation-paused-drain`
rewrite the worker's kubelet config and restart the kubelet; `taint-eviction`
taints the worker; `shipper-restart` restarts every shipper; `node-crash` and
`node-crash-loki-down` `docker kill` the worker node and start it again.
`slow-reader-drain` and `restart-while-behind` only mean something with shippers CPU-limited, which is
done by hand:

```bash
kubectl --context kind-evict-lab -n logging patch ds <name> --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"25m"},"limits":{"cpu":"25m","memory":"1Gi"}}}]'
```

Restore afterwards by replacing `resources` with the values in the manifest
(`kubectl apply` alone does not remove the added CPU limit).

Each run writes `results/<scenario>-<run>.json` with the observations (pod
status, `kubectl logs` result, files on the node, over time) and the per-shipper
score: lines delivered, duplicates, missing sequence ranges, and whether the
SIGTERM/exit lines arrived.

How scoring works: the test pod writes `run=<id> seq=N` lines to stdout and the
same lines to a hostPath file (`/var/lab-truth/<pod>.log` on the worker), which
survives eviction and is the ground truth. Loki is queried by line content, not
labels, so a line that lost its Kubernetes metadata still counts and its label
set shows up in the report.

## Tear down

```bash
kind delete cluster --name evict-lab
docker rm -f evict-lgtm
```
