# Findings: getting evicted pod logs into Loki

Lab: kind v0.30 / Kubernetes v1.34.0, containerd, Loki 3.7.8, Grafana 13.2, all
on one Windows/WSL2 machine. Shippers tested:
- Fluent Bit 5.1.5 and Promtail 3.6.11 (all sections);
- Grafana Alloy v1.20.1, OpenTelemetry Collector contrib 0.162.0 and Vector
  0.59.0 (round 2).

Setup and how to rerun everything: [README.md](README.md). Raw results: `results/*.json`.

## Short answer

1. **Logs from an evicted pod can only be collected while the eviction is happening.**
   The node deletes them right after: about 3 seconds after a kubelet eviction,
   and the moment the pod object is deleted after an Eviction-API eviction.
   `kubectl logs` fails from then on. Nothing can be recovered from the node later.
2. **Fluent Bit, tuned, was the most complete shipper.** It discovers new files
   within 1s and normally reads them faster than the kubelet deletes them.
   After a file is deleted it keeps reading for `rotate_wait` only (default
   5s), and not at all while its input is paused (round 3). Set
   `rotate_wait: 300` and filesystem buffering.
   Promtail stops a file's tailer as soon as the file (or, with
   `kubernetes_sd`, the pod object) goes away. Whatever it had not read yet is lost.
   In round 2, **Alloy matched it**, with 100% in all 18 runs.
3. **Stock settings miss short-lived pods.** Fluent Bit's default
   `refresh_interval` is 60s, and with it Fluent Bit missed most pods that
   lived under a minute.
   - `refresh_interval` only controls how often Fluent Bit looks for *new
     files*. Lines written to a file it already tails are read on each write
     (inotify), so the last lines of a known pod are not at risk.
   - With the 60s default, Fluent Bit got the last 15 and the last 20,000 lines
     right before eviction in 9 of 9 runs.
   - A 1s refresh cost about 1 mCPU more than 60s at 1,000 files.
4. **Holding the pod open fixes the shipper race for API evictions.** A native
   sidecar that sleeps 5s on SIGTERM keeps the app's log file on disk after its
   last line. With it, every shipper got 100%, including promtail-sd, which
   lost 100% of the same burst without it.
5. **What happened is a separate question from what the pod said.** Ship three extra
   streams so an eviction can be explained after the fact:
   - Kubernetes events: kubelet evictions only.
   - API server audit log: Eviction-API calls, including PDB refusals.
   - A pod-lifecycle watcher: the DisruptionTarget condition plus the last log
     lines from the pod status.

## Results

Each test pod writes numbered lines. A second copy goes to a hostPath file as
ground truth. "6/6" means every line arrived in all 6 runs.

| scenario | runs | lines/run | fluent-bit (tuned) | fluent-bit-defaults | promtail-sd | promtail-static |
|---|---|---|---|---|---|---|
| api-eviction: Eviction API, 30s grace, pod lived ~12s | 6 | 110 | 6/6 | 1/6 (84% lost) | 6/6 | 6/6 |
| api-eviction-fast: evicted 1s after Ready, no grace | 6 | 90 | 6/6 | 1/6 (82% lost) | 6/6 | 6/6 |
| api-eviction-slow: pod lived 90s | 1 | 452 | 1/1 | 1/1 | 1/1 | 1/1 |
| kubelet-ephemeral-fast: exceeds ephemeral-storage limit | 6 | 438 | 6/6 | 1/6 (76% lost) | 6/6 | 6/6 |
| node-memory-pressure: real node-pressure eviction | 1 | 172 | 1/1 | 1/1 | 1/1 | 1/1 |
| log-burst-api: 15 MB of logs, then evicted with no grace | 5 | 100,007 | 4/5 (20% lost) | 0/5 (100% lost) | 0/5 (93% lost) | 3/5 (20% lost) |
| log-burst-kubelet: 45 MB of logs breaks its own ephemeral limit | 5 | 300,033 | 4/5 (6% lost)* | 0/5 (100% lost) | 2/5 (15% lost) | 2/5 (15% lost) |
| log-burst-api, Loki at its default 4 MB/s limit | 1 | 100,018 | 1/1 | 0/1 | 0/1 (100% lost) | 0/1 (47% lost) |
| log-burst-kubelet, Loki at its default 4 MB/s limit | 1 | 300,086 | 1/1 | 0/1 | 0/1 (48% lost) | 0/1 (82% lost) |
| shipper-outage-kubelet: shippers off the node for 30s | 1 | 211 | 0/1 (100% lost) | 0/1 | 0/1 | 0/1 |
| control-crash: container exits by itself, no eviction | 1 | 100 | 1/1 | 1/1 | 1/1 | 1/1 |

\* That 6% is one run in which every shipper lost the same first 94,602
lines. The kubelet rotated the file at 10 MiB before any shipper had opened it
(see "Log rotation" below), so this is not a Fluent Bit-specific loss.

Small samples: 1 to 6 runs per row, on one machine. Treat the percentages as
evidence of failure modes, not as rates to expect in production.

Separate check: a real `kubectl drain` of a two-replica Deployment protected by
a PDB. The drain evicted three pods that had each lived 3 to 4 seconds.
Fluent Bit and promtail-static delivered all of their lines, including the
SIGTERM line. **promtail-sd delivered none.** The pod objects were gone before
it had opened the files.

## What the node keeps after an eviction

Observed by polling every 2 seconds after each eviction:

| | kubelet eviction (node pressure, ephemeral storage) | Eviction API (drain, autoscaler, Karpenter) | container crash (control) |
|---|---|---|---|
| pod object | stays, `phase=Failed reason=Evicted` | deleted after the grace period | stays |
| log file on node | deleted about 3s after eviction; pod log dir gone within 12-38s | deleted with the pod object | stays |
| `kubectl logs` | works for about 3s, then `unable to retrieve container logs` | `NotFound` once the pod is deleted | works |
| termination message (`FallbackToLogsOnError`) | last lines kept in pod status in 8 of 11 runs; the other 3 had `ContainerStatusUnknown` or an empty message | gone with the pod object | kept |
| Kubernetes event | `Evicted` with the reason (e.g. "node was low on resource: memory ... Container app was using 728632Ki") | **none**; only `Killing` | none |

Kubelet hard evictions sent SIGTERM and then killed the container about 2
seconds later. The test app's shutdown handler got two lines out every time.

## Why the shippers differ

**Discovery latency.** The shipper has to open the file before it disappears.
- Fluent Bit rescans every `refresh_interval`: 60s by default, 1s here.
- Promtail `kubernetes_sd` gets the pod from an API watch, then waits for the
  file glob, which re-runs every `target_config.sync_period` (10s default, 2s here).
- promtail-static waits for the same glob.

A pod that lives for less than the discovery interval is missed entirely if its
files are removed with it. That is the API-eviction case and the
fluent-bit-defaults column.

**Draining deleted files.** Fluent Bit delivered complete 300k-line bursts.
Round 3 showed this was mostly because it kept up, not because it drains deleted
files without limit: it reads a deleted file for `rotate_wait` seconds only.
Promtail logs `stopped tailing file` and drops the unread part when its target
goes away:
- With `kubernetes_sd`, the target is removed when the pod object is deleted.
  That makes promtail-sd the worst option for API evictions: it lost 93% of
  burst lines and every line of the 3-second drained pods.
- With a static glob, the target is removed at the next `sync_period` after the
  file disappears. That gives promtail-static a short grace window, so it does
  better (3/5 complete).

**Backpressure makes the draining gap bigger.** With Loki at its default
per-tenant limit (4 MB/s, 429 responses), every shipper fell behind. Fluent Bit
buffered on disk and retried until everything was delivered. Promtail's tailers
were stopped while its client was still blocked, so it lost 47-100% of lines.
A node drain is exactly when many pods flush logs at once, so Loki's ingestion
limits matter here.

**Kubernetes metadata.** Fluent Bit's `kubernetes` filter always attached
namespace, pod and container labels, even for pods deleted within about a
second. No run produced unlabelled lines.

**Log rotation.** The kubelet rotates `0.log` at `containerLogMaxSize` (10 MiB
default). Both shippers here only follow the live file:
`/var/log/containers/*.log` or `/var/log/pods/*/*/*.log`. A burst that is
rotated away before the shipper opens the file is invisible to both.

**Open question.** In 1 of 5 log-burst-api runs, Fluent Bit delivered only the
final line of a 15 MB file. The pod's container lived about 1.5s, and Fluent Bit
watched the file for 0.54s before the kubelet removed it. Fluent Bit's own
counters show input = output = 1,102,734 records with zero errors or retries,
so the lines were never read rather than dropped in the pipeline. Inode reuse
was checked and ruled out. The root cause is not determined.

## Round 2: refresh_interval, other shippers, and a grace sidecar

### refresh_interval controls discovery, not reading

Fluent Bit's tail input does two separate jobs:
- **Discovery.** It re-scans the `path` glob every `refresh_interval` (default
  60s) to find new files.
- **Reading.** For files it already watches, inotify tells it about every
  write, and it reads the new lines right away. There is no polling interval.
  Measured read latency was the same at 1s, 10s and 60s refresh (round 3).
  If the file is then deleted, Fluent Bit keeps reading it for `rotate_wait`
  seconds, and only while its input is not paused (round 3).

So the case "85 lines read, 15 written just before eviction" does not depend
on `refresh_interval`. The interval only matters for a pod that is evicted
before its file has been discovered: one younger than the interval, plus the
~3s the kubelet leaves the files after a kubelet eviction.

Test: the pod logged 1 line/s for 80s, so that even the 60s-refresh instance
was tailing it (checked in Loki before continuing). It then wrote its final
lines in one go and was evicted at once.

| scenario | runs | fluent-bit (1s) | fluent-bit-defaults (60s) | promtail-sd | promtail-static |
|---|---|---|---|---|---|
| late-burst-api-15: last 15 lines, then Eviction API, no grace | 3 | 3/3 | 3/3 | 2/3, SIGTERM/exit lines lost in 3/3 | 3/3 |
| late-burst-api-20k: last 20,000 lines, then Eviction API, no grace | 3 | 3/3 | 3/3 | 1/3 (43% lost) | 3/3 |
| late-burst-kubelet-20k: last 20,000 lines, then kubelet eviction | 3 | 3/3 | 3/3 | 3/3 | 3/3 |

### What refresh_interval costs

`bench/refresh_cost.py` ran three Fluent Bit pods on the worker. They were
identical except for `refresh_interval`, tailed the same directory, and sent
output to `null`. One file in ten got a line per second. CPU was measured over
120s from containerd.

| watched files | refresh 1s | refresh 10s | refresh 60s |
|---|---|---|---|
| 100 | 0.5 mCPU | 0.4 mCPU | 0.3 mCPU |
| 1,000 | 3.1 mCPU | 2.0 mCPU | 1.9 mCPU |

A scan is a directory listing plus a stat per file. A busy node has a few
hundred container log files, so 1s versus 60s is about 1 mCPU. Not measured:
- the `kubernetes` filter, which does an API lookup per new file whatever the
  interval;
- slow or network disks;
- memory.

### Other shippers

Same scenarios, all seven shippers running side by side. Discovery was set to
about 1s for each: Alloy `sync_period: 1s`, Vector
`glob_minimum_cooldown_ms: 1000`. The OTel Collector kept its 200ms
`poll_interval` default.

| scenario | runs | fluent-bit | fluent-bit-defaults | promtail-sd | promtail-static | alloy | otel-filelog | vector |
|---|---|---|---|---|---|---|---|---|
| api-eviction-fast | 3 | 3/3 | 0/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 |
| late-burst-api-20k | 3 | 3/3 | 3/3 | 2/3 (14% lost) | 3/3 | 3/3 | 3/3 | 3/3 |
| log-burst-api | 3 | 3/3 | 1/3 | 0/3 (100% lost) | 2/3 (3% lost) | 3/3 | 3/3 | 2/3 (33% lost) |
| log-burst-kubelet | 6 | 6/6 | 0/6 | 3/6 (15% lost) | 2/6 (18% lost) | 6/6 | 2/3 (last 4 lines lost once)* | 6/6 |
| log-burst-api-grace (with sidecar, below) | 3 | 3/3 | 1/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 |

\* Three OTel runs are excluded; see the batching trap below.

- **Grafana Alloy** (`loki.source.file` with a `/var/log/pods` glob) delivered
  everything in all 18 runs. Round 3 showed that was speed, not draining:
  CPU-starved, it closed the file at deletion, much like Promtail. It is still
  the natural replacement if you are on Promtail today.
- **OpenTelemetry Collector `file_log`** was complete except for the last 4
  lines of one file the kubelet deleted. In round 3 it was the only shipper
  that, CPU-starved, still read a deleted file to the end. It sends OTLP
  straight to Loki's `/otlp` endpoint, and Loki turns `k8s.namespace.name`,
  `k8s.pod.name` and `k8s.container.name` into labels.
- **OTel batching trap.** With the `batch` processor's default (no maximum
  size), these long lines produced 4.2 MB OTLP requests. Loki rejected each
  one with HTTP 503 (`grpc: received message larger than max (4214950 vs.
  4194304)`). The collector retried the same request forever, and its
  persistent queue blocked everything behind it, across restarts too. The fix
  is `send_batch_max_size` (set to 1000 here). After a fix, the stuck queue on
  disk has to be cleared. Any shipper that batches by count rather than bytes
  can hit this limit.
- **Vector** lost a whole 1.5s pod in one run; its log has no trace of ever
  finding the file. Like promtail-sd, Vector discovers pods through the API
  before it globs their files. Once it had a file, it kept reading it after
  deletion (round 3).

### A grace sidecar keeps the files around (API evictions)

After an Eviction-API eviction, the kubelet deletes the pod, and with it the
log files, once every container has stopped. A native sidecar (an init container
with `restartPolicy: Always`) is stopped only after the app container has
exited. If it sleeps on SIGTERM, the app's file stays on disk for that long
after the app's last line:

```yaml
spec:
  terminationGracePeriodSeconds: 15     # must cover app shutdown + the sleep
  initContainers:
    - name: log-grace
      image: busybox:1.37.0
      restartPolicy: Always             # native sidecar (GA in Kubernetes 1.33)
      command: ["sh", "-c", "trap 'sleep 5; exit 0' TERM; while :; do sleep 1; done"]
      resources: {requests: {cpu: 1m, memory: 4Mi}}
```

On the 15 MB burst with an immediate eviction:
- **promtail-sd** went from 0/3 (100% lost) to 3/3.
- **promtail-static** and **Vector** also reached 3/3.
- It does not help a shipper that has not discovered the pod yet:
  fluent-bit-defaults (60s refresh) stayed at 1/3.

It was not tested with kubelet evictions, and it is not expected to help there.
In every kubelet eviction the kubelet killed the containers about 2s after
SIGTERM and deleted their logs, whether or not the pod object stayed.

## Round 3: proving the read path, and edge cases

### Reading is event-driven; discovery is not

`bench/read_latency.py`: the test pod writes a line only when the harness drops
a trigger file on the node. The harness times each line to Loki on one clock,
for three Fluent Bit instances that differ only in `refresh_interval`.

| refresh_interval | discovery: pod created -> first line in Loki | read latency, file already tailed (12 lines) |
|---|---|---|
| 1s | 2.9s | median 0.75s, max 1.26s |
| 10s | 2.7s (scan happened to land early) | median 0.58s, max 1.36s |
| 60s | 24.5s | median 0.60s, max 1.05s |

Lines on a file Fluent Bit already tails arrive in about a second, whatever the
refresh interval. Only finding new files waits for the interval.

### A pod that lives and dies inside one refresh window

Pods were evicted through the API about 1s after Ready, about 2-3s of life in
total. `fb-proof` is a Fluent Bit instance with `refresh_interval: 10`.

| | refresh 1s (fluent-bit) | refresh 10s (fb-proof) | refresh 60s (defaults) | Alloy / OTel / Vector / Promtail (1-2s) |
|---|---|---|---|---|
| no sidecar, 8 runs | 8/8 | **2/8** (6 missed entirely) | 0/8 | 8/8 each |
| 12s log-grace sidecar, 8 runs | 8/8 | **8/8** | 2/8 | 8/8 each |

A file that exists for less than the discovery interval is only caught if a scan
happens to land inside its life. Two things close the gap:
- **For any eviction:** a discovery interval shorter than the time the file
  exists. Kubelet evictions leave the files about 3s, so `refresh_interval` of
  2s or less always catches a kubelet-evicted pod, however young.
- **For API evictions and deletions:** a grace sidecar that sleeps longer than
  the interval.

### Reading a deleted file when the shipper is behind

The earlier tests could not tell "reads deleted files" apart from "read it
before it was deleted". Two tests force the shipper to be behind at deletion
time.

**Input paused by the memory buffer.** Loki was frozen (`docker pause`) while a
known pod wrote 20k lines (or 80k with rotation at 1 MiB) and was evicted.
- fb-proof (`mem_buf_limit: 512KB`, memory buffering) logged
  `tail.0 paused (mem buf overlimit)`. The file was deleted during the pause,
  and after `resume` the rest was never read: **lost 94% / 71%**.
- The tuned Fluent Bit (filesystem buffering, which never pauses the input),
  Alloy, the OTel Collector and Vector kept reading into their buffers and
  delivered 100%.
- Promtail (both jobs) stopped reading while its client was blocked and lost
  over 99%.

**CPU-starved reader.** Every shipper was limited to 25m CPU. A pod logged
45 MB, and the kubelet evicted it and deleted the file about 3s later.

| shipper | delivered | still holding the deleted file open |
|---|---|---|
| OTel Collector | 300,028 / 300,028 | yes, at +120s |
| Vector | 135,882 at scoring; 268,806 when I restarted it mid-drain | yes, at +120s |
| Fluent Bit, `rotate_wait: 30` | 102,268 and 162,904 (two instances) | yes at +20s, closed by +60s |
| Alloy | 12,590 | no, closed at deletion |
| Promtail sd / static | 9,991 / 9,319 | no, closed at deletion |
| **Fluent Bit, `rotate_wait: 300`** (separate run, same throttle) | **300,072 / 300,072** | yes at +20s, finished by +60s |

Kubernetes removes the `/var/log/containers` symlink, and Fluent Bit treats
that as a rotation. It keeps reading the file for `rotate_wait` seconds (default
**5s**) and then closes it, finished or not. `manifests/10-fluent-bit.yaml` now
uses 300. The cost: a deleted file keeps its disk space until Fluent Bit closes
it, which works against the kubelet under disk pressure.

### Other edge cases

| edge case | result | what to do |
|---|---|---|
| **Very long last line** (stack trace): 100 KB and 1 MB lines, then immediate eviction | 100 KB arrived intact from all shippers (the 16 KB CRI pieces were rejoined). **1 MB was dropped by Loki for every shipper**: `loki_discarded_samples_total{reason="line_too_long"}`, `max_line_size: 256KB`. Shippers saw a successful push and logged nothing. | Raise Loki's `max_line_size`, or set `max_line_size_truncate: true` to keep the start of the line. Alert on `loki_discarded_samples_total`. |
| **Rotation during a burst** | In the CPU-starved run, lines 1-55,676 (the first rotated segment) were lost by both Promtails, the OTel Collector and fb-proof. Tuned Fluent Bit, Alloy and Vector had opened the file before it rotated and followed it. | Make `containerLogMaxSize` (default 10Mi) bigger than your largest bursts where the disk allows. Keep discovery fast. |
| **Force delete** (`--grace-period=0 --force`) | The pod object is gone at once, but the container kept running and logging until the kubelet killed it; the files were gone about 8s later. promtail-sd lost the last 2 lines and the SIGTERM line. Everything else was complete. | Avoid API-tied discovery (promtail-sd). Force deletes also skip the grace sidecar. |
| **Shipper restart** mid-pod | All tuned shippers: complete, 0 duplicates. fluent-bit-defaults lost lines 1-341: the file was not yet in its DB, and with `read_from_head: false` it started at the end of the file. | `read_from_head: true` and the DB on hostPath. |
| **Shipper restart while draining a deleted file** | Vector stopped short by 31,222 lines when I restarted it mid-drain. The open handle was the only copy. | Do not roll log DaemonSets during drains or pressure events. |
| **Shipper without tolerations** | A `NoExecute` taint evicted the test pod and fb-proof (no tolerations) in the same second; fb-proof lost the pod's last 4 lines. Shippers with `tolerations: [{operator: Exists}]` were unaffected. | Tolerate everything on log DaemonSets: not-ready, unreachable and custom taints evict workloads and shippers together. |
| **Scheduler preemption** | Graceful delete; event `Preempted`; lifecycle `disruption=PreemptionByScheduler`. All shippers complete. | Already visible on the dashboard (events and lifecycle panels). |
| **Taint-based eviction** | Event `TaintManagerEviction`; lifecycle `disruption=DeletionByTaintManager`. | Same. |
| **Disk-pressure eviction** (nodefs threshold set just below current free space) | Real eviction: "low on resource: ephemeral-storage". Same timeline as memory: files deleted about 3s after. **Collateral:** an earlier crashed pod, not evicted itself, had its log file deleted by the kubelet's disk reclaim, and `kubectl logs` failed for it. Shippers already had its lines. | Ship logs from all pods, not only evicted ones. Under disk pressure, the node deletes logs of finished pods too. |

Not tested, from how Kubernetes works:
- **Node crash, or spot loss without a drain.** The node's disk, and any shipper
  buffer on it, is gone; only lines already pushed survive. Keep flush intervals
  short. For graceful node shutdown, set kubelet
  `shutdownGracePeriodCriticalPods` so `system-node-critical` shippers stop last.
  Spot interruption handled by Karpenter or a node termination handler is a drain,
  which is the API-eviction path tested above.
- **StatefulSet pod-name reuse.** `web-0` evicted and recreated is the same `pod`
  label. Add the pod UID or container ID as structured metadata (not a label) to
  tell the instances apart.
- **Crash-looping before eviction.** The kubelet keeps only the most recent
  terminated container's log; older restarts are deleted at the next restart.
  Restart backoff (10s up to 5m) usually leaves enough time to discover them.
- **Apps that log to files** inside the container, not stdout. None of these
  shippers see those files, and they disappear with the pod. Log to stdout, or
  use a shared volume plus a sidecar shipper, which dies with the pod.
- **New nodes.** A pod evicted before the node's shipper is running is lost.
  Keep a startup taint on new nodes until the log DaemonSet is ready
  (Karpenter `startupTaints`, or a readiness gate).
- **Terminated-pod GC** (12,500 pods by default) removes evicted pod objects, and
  their termination messages, in busy clusters. The lifecycle watcher records
  them at the time.
- **Late backfill.** Loki rejects entries far behind a stream's newest entry
  (`too_far_behind`) or older than `reject_old_samples_max_age` (default 1 week).
  This session recorded 5,512 `too_far_behind` rejections. Loki's logging is off
  in this image, so I could not tell which shipper sent them; the likely source
  is the OTel Collector re-reading old files after I cleared its state.
- **API server overload during a drain storm.** The Fluent Bit `kubernetes` filter
  needs the API for metadata, and API failures were not simulated. Path-based
  labels (Alloy, promtail-static, the OTel `container` operator) do not depend on it.

## Round 4: closing the remaining gaps

Three gaps were left after round 3:
- force-deleted short-lived pods (no grace period, so no sidecar);
- shipper restarts while lines exist only in a deleted file;
- node crash or spot loss without a drain.

Two components were added:
- **log-keeper** (`manifests/50-log-keeper.yaml`), with a Fluent Bit instance
  that ships only what it keeps (`fb-keep`, deliberately left at
  `refresh_interval: 10`).
- **A two-tier path** (`manifests/60-aggregator.yaml`): node agents forward to a
  Fluent Bit aggregator on another node, with acknowledgements (`fb-via-agg`).

### How log-keeper works

A small DaemonSet watches `/var/log/pods` with inotify. The moment the runtime
creates a container log file, it makes a **hard link** to it in `/var/log/keep/`.
A hard link is a second name for the same file:
- appends to the original show up in the link;
- when the kubelet deletes the original (eviction, force delete, rotation
  cleanup), the data stays on disk under the kept name.

The shipper reads the kept files at its own pace, with labels taken from the
path. Kept files are removed:
- 10 minutes after the original is deleted (the inode's ctime records the unlink);
- or sooner if orphaned data passes `KEEP_MAX_MB` (default 1024), oldest first.

The size cap was checked with synthetic files: 4.5 MB of orphans against a
2 MB cap dropped the oldest 3 MB file.

### Force-deleted pods that live about 1s (8 runs)

| | fluent-bit (1s) | fb-proof (10s) | **fb-keep (10s + keeper)** | fluent-bit-defaults (60s) | others (1-2s) |
|---|---|---|---|---|---|
| complete runs | 8/8 | 5/8 | **8/8** | 0/8 | 7/8 to 8/8 |

The pods had a 12s grace sidecar; a force delete skips it. After deletion, each
pod's original files were gone, and its kept file had link count 1 and about
7.5 KB of data.

### Shipper restart while behind (CPU limited to 25m, 45 MB burst, kubelet eviction, every shipper restarted 10s later)

| shipper | delivered of 300,097 |
|---|---|
| **fb-keep** | **300,097** |
| fb-via-agg (agent tails `/var/log/containers`) | 109,356 |
| fluent-bit | 96,805 |
| OTel Collector | 30,598 |
| Alloy | 27,340 |
| promtail-static / promtail-sd | 18,856 / 15,738 |
| Vector | 12,924 |
| fb-proof / fluent-bit-defaults | 79 / 0 |

Just before the restart, Fluent Bit, the OTel Collector and Vector still held the
deleted file open; the restart dropped those handles. The kept file was a normal
file on disk, so fb-keep resumed from the position in its DB.

### Node crash (`docker kill` of the worker node, about 100 lines/s)

**While the node is gone** (the spot-loss case: nothing on that node can be recovered):

| | Loki healthy | Loki unreachable for 20s first |
|---|---|---|
| fb-via-agg (aggregator) | 31 lines lost (~0.3s) | **47 lost (~0.5s)** |
| fluent-bit (direct, disk buffer on the node) | 31 lost | 506 lost |
| fb-keep (direct) | 31 lost | 876 lost |
| promtail-sd / static | 33 / 23 lost | 1,807 / 1,838 lost |
| Alloy / OTel / Vector | 93 / 69 / 82 lost | 1,748 / 1,265 / 1,683 lost |

With Loki healthy, every shipper loses only what was not yet pushed, under a
second. When Loki is slow or down, a direct shipper's backlog sits on the node
and dies with it. The aggregator had acknowledged and stored that backlog on
another node.

The frozen Loki processed some requests that were already in its socket buffers
when it thawed. That is why the direct Fluent Bit columns show scattered
partial deliveries; a Loki that was really down would not do this.

**After the node reboots** (the kernel-panic or power-cut case, where the node
comes back), first-container lines recovered:

| | Loki healthy (last 31 lines) | Loki down first (3,714 lines) |
|---|---|---|
| fluent-bit, fb-keep, fb-via-agg, Vector | 31/31 | 3714/3714 |
| promtail-sd / static | 31/31 | 3698 / 3696 |
| OTel Collector | 13/31 | 3659 |
| fb-proof (memory buffer) | **0/31** | 3621 |
| Alloy | 31/31 | **2879** |

The log files were still on disk, so a shipper recovers if its saved position
did not move past lines it had not delivered. fb-proof buffers in memory and its
DB position had already advanced; Alloy's `loki.write` queue is in memory by
default. Docker's VM kernel did not crash in these tests, so data not yet
flushed to disk survived. A real power cut can lose the last few seconds of the
log file itself.

### What these add, and what they cost

- **log-keeper** makes the file outlive every way the kubelet deletes it. Short
  pods, force deletes and restarts mid-drain stop mattering. `refresh_interval`,
  `rotate_wait` and the grace sidecar become much less critical, though they
  still help.
  Costs:
  - kept data uses disk until the TTL or the cap, which the kubelet does not see
    when it is trying to free space;
  - it needs read-write hostPath access to `/var/log`, and hard links only work
    within one filesystem;
  - if the keeper is down, you are back to plain tailing;
  - it is a home-grown component (about 70 lines of shell) that you would own.
- **The aggregator** moves the backlog off the node. Costs:
  - another component to run, highly available, with a PersistentVolume (one
    replica on a hostPath here);
  - forward acknowledgements add a round trip;
  - `storage.sync: full` costs disk I/O.
- **Backfill caveat.** Loki rejects entries more than about an hour behind a
  stream's newest entry (`too_far_behind`). Starting fb-keep and the aggregator
  agent on a node that had been up for hours triggered this for old rotated
  segments; it is a one-time effect at rollout.

Not tested:
- **Spot interruption handling** (Karpenter's interruption queue, or
  aws-node-termination-handler). It turns the 2-minute spot notice into a
  cordon and drain, which is the Eviction-API path tested above. This is the
  main fix for spot loss and needs no logging changes.
- **Logging straight from the app** (an OTLP SDK or log appender) skips node
  files, but the app's in-process batch dies with it.
- **Fluent Bit `hot_reload`** for config changes without restarting the pod.
- **DaemonSet `maxSurge`** to start the new shipper before the old one stops.
  Two instances sharing one position DB need care.

## Recommended setup

Each layer covers a failure the others cannot:

1. **Node agent**: Fluent Bit with fast discovery, `read_from_head`,
   `rotate_wait: 300`, filesystem buffering, unlimited retries,
   `system-node-critical`, tolerate everything.
2. **log-keeper** under it. The files survive deletion, force delete, rotation
   and shipper restarts.
3. **Aggregator tier** with acknowledgements and a persistent volume. A slow Loki
   builds backlog off the node, so a node crash costs under a second of logs.
4. **Spot interruption handling** so spot loss becomes a drain.
5. **Workloads**: stdout logging, a flush on SIGTERM,
   `FallbackToLogsOnError`. A grace sidecar is optional once the keeper runs.
6. **Loki**: `max_line_size` or truncation, ingestion limits sized for drains,
   alerts on `loki_discarded_samples_total`.
7. **Context**: events, the audit log, and the pod-lifecycle watcher, so every
   loss is at least explained.

What remains: lines written in the last moments before a node dies, under a
second with the aggregator; and anything lost when the node's own disk loses
data in a power cut.

## Recommendations

### 1. During eviction: the node agent (this is where the logs are)

Fluent Bit settings that made the difference (`manifests/10-fluent-bit.yaml`):

```yaml
- name: tail
  path: /var/log/containers/*.log
  multiline.parser: cri
  refresh_interval: 1          # new-file discovery only (reading is per write). <= 2s always catches
                               # kubelet-evicted pods (files last ~3s); 10s missed 6/8 pods that lived 2-3s.
                               # ~1 mCPU more than 60s at 1,000 files.
  read_from_head: true         # files found late, or after a restart, are read from the start
  rotate_wait: 300             # how long a DELETED pod log is still read (default 5s); 30 lost 46% when behind
  db: /var/lib/fluent-bit/tail.db      # hostPath, so restarts resume
  storage.type: filesystem             # with service.storage.path on hostPath. Memory buffering with
                                       # mem_buf_limit pauses the input, and a file deleted during
                                       # the pause is not read after resume (lost 94%).
# output loki: retry_limit: false      # never drop on 429 or Loki outage
# pod: priorityClassName: system-node-critical, so node-pressure eviction
#      takes the workloads before the shipper
# pod: tolerations: [{operator: Exists}], so NoExecute taints do not evict it with the workloads
```

On the Loki side, raise `max_line_size` or set `max_line_size_truncate: true`
(a 1 MB stack-trace line was dropped silently for every shipper). Alert on
`loki_discarded_samples_total`.

If you are on Promtail, move to Alloy. `manifests/40-alloy.yaml` (a
`/var/log/pods` glob with labels from the path) was as complete as tuned
Fluent Bit in every round-2 run. Until you move:
- Prefer a static `/var/log/pods/*/*/*.log` job, with labels taken from the
  path, over `kubernetes_sd`. It does not depend on the pod object. It did
  at least as well in every round-1 scenario except the rate-limited kubelet burst,
  where it lost 82% against promtail-sd's 48%.
- Keep `sync_period` short.
- Size Loki's ingestion limits for drain bursts.

Promtail will still lose the unread part of any file deleted while it is behind.

With the OTel Collector, cap batches (`send_batch_max_size`) below Loki's
4 MiB gRPC limit. An uncapped batch can wedge the persistent queue.

### 1b. For API evictions: give the shipper a few seconds

Add the `log-grace` native sidecar from round 2 to workloads whose last lines
matter. It holds the pod for a few seconds after the app exits, and needs
`terminationGracePeriodSeconds` large enough to include that time. Every
shipper that had already discovered the pod then got 100%. It does not change
kubelet evictions.

### 2. Right before the container dies: put the last lines in the pod status

Set `terminationMessagePolicy: FallbackToLogsOnError` on containers. On a
non-zero exit, which includes evictions (137), the kubelet copies the log tail
(up to 80 lines / 2 KB) into the pod status. It stays there as long as the pod
object does. For kubelet-evicted pods, that is until someone deletes the pod
or the cluster passes the terminated-pod GC threshold (12,500 pods by
default). API-evicted pods are deleted at once, so for them it is not there at all. The tail was present in 8 of 11 kubelet evictions.

### 3. After eviction: what can still be recovered

Only what's in the API, and only while the pod object exists.
`manifests/30-pod-lifecycle.yaml` watches pods and prints one JSON line per
terminal state. The shippers then carry it to Loki like any other log. Each line
includes:
- `status.reason` / `message`
- the `DisruptionTarget` condition
- the termination message lines

In the shipper-outage run, every shipper lost 100% of the pod's lines, but this
stream still had the eviction reason and the last 10 lines, including the
SIGTERM line.

### 4. Explaining why a pod went away

| what happened | where it shows up |
|---|---|
| kubelet eviction (memory, disk, ephemeral storage) | event `reason=Evicted` (events collector); lifecycle `disruption=TerminationByKubelet` |
| Eviction API (drain, cluster-autoscaler, Karpenter) | **no event**. Audit log `pods/eviction create`, 201 (who did it); lifecycle `disruption=EvictionByEvictionAPI` |
| eviction blocked by a PDB | audit log, response code 429 (24 refusals recorded in the drain test) |

The Grafana dashboard `dashboards/evicted-pods.json` puts all of this on one
page: eviction events, the selected pod's last lines per shipper, lines per
shipper, audit evictions, and lifecycle records with the last lines.

## Not verified

- Disk pressure was induced by lowering the `nodefs.available` threshold to
  just under current free space, not by filling the disk (1 run). `imagefs`
  pressure and image GC were not observed.
- Round 3 edge cases ran once each (the refresh-window test 8 times). The
  `rotate_wait` fix was one throttled run at 30 and one at 300; the open-file
  checks back up the mechanism, but the sample is small.
- The exact Fluent Bit code path behind "not read after resume" was inferred
  from behaviour (no further write event arrives for a deleted file), not
  confirmed in its source.
- Fluent Bit Helm chart defaults.
- Alloy, Vector and the OTel Collector: 3 to 6 runs per scenario, only with
  discovery tuned to about 1s (OTel at its 200ms default), and not under Loki rate
  limiting or in the shipper-outage scenario. Vector's drain of a deleted file
  was cut short by my restart, so its final count is not known. Alloy with `discovery.kubernetes`
  (API-driven targets, like promtail-sd) was not tried; only the path glob was.
- The grace sidecar with kubelet evictions.
- `refresh_interval` cost with the `kubernetes` filter, on slow disks, or for memory.
- Multi-node and real-cloud behaviour: autoscaler or Karpenter scale-down, spot
  interruption, node shutdown. The Eviction-API path was exercised with direct
  API calls and `kubectl drain`, which is the call those tools make.
- Root cause of the one Fluent Bit burst miss described above.
- The dashboard queries were checked through the Loki API. The rendered panels
  were not visually reviewed.
