"""Evicted-pod log experiments: run a scenario, then score each log shipper.

Usage:
    python lab.py run <scenario> [--keep]
    python lab.py list

Each scenario starts a pod that writes numbered lines ("run=<id> seq=N") to
stdout and, as ground truth, to a hostPath file on the node. After the eviction
it queries Loki by line content (not by labels, so lines that lost their
Kubernetes metadata are still counted) and compares every shipper against the
ground truth. Results are printed and saved under results/.
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

CONTEXT = "kind-evict-lab"
NAMESPACE = "evict-test"
WORKER = "evict-lab-worker"
LOKI = "http://127.0.0.1:23100"
# Column name -> Loki stream selector. OTLP pushes carry no "shipper" label; Loki
# derives service_name from the resource attribute set in 41-otel-filelog.yaml.
SHIPPERS = {
    "fluent-bit": '{shipper="fluent-bit", container!="watch"}',
    "fluent-bit-defaults": '{shipper="fluent-bit-defaults", container!="watch"}',
    "fb-proof": '{shipper="fb-proof", container!="watch"}',
    "fb-keep": '{shipper="fb-keep", container!="watch"}',
    "fb-via-agg": '{shipper="fb-via-agg", container!="watch"}',
    "promtail-sd": '{shipper="promtail-sd", container!="watch"}',
    "promtail-static": '{shipper="promtail-static", container!="watch"}',
    "alloy": '{shipper="alloy", container!="watch"}',
    "otel-filelog": '{service_name="otel-filelog", k8s_container_name!="watch"}',
    "vector": '{shipper="vector", container!="watch"}',
}
LABEL_KEYS = ("namespace", "pod", "container", "k8s_namespace_name", "k8s_pod_name", "k8s_container_name")
RESULTS = Path(__file__).parent / "results"

APP_SCRIPT = r"""
i=0
log() { echo "$1"; echo "$1" >> /truth/$POD_NAME.log; }
shutdown() {
  log "run=$RUN event=SIGTERM last_seq=$i"
  j=0
  while [ $j -lt $LINGER ]; do j=$((j+1)); i=$((i+1)); log "run=$RUN seq=$i phase=shutdown"; sleep 1; done
  log "run=$RUN event=exit last_seq=$i"
  exit 0
}
trap shutdown TERM
log "run=$RUN event=start"
if [ "$BURST" -gt 0 ]; then
  log "run=$RUN event=burst-start lines=$BURST"
  awk -v r="$RUN" -v n="$BURST" 'BEGIN { pad = sprintf("%120s", ""); gsub(/ /, "x", pad);
    for (k = 1; k <= n; k++) printf "run=%s seq=%d phase=burst pad=%s\n", r, k, pad }' \
    | tee -a /truth/$POD_NAME.log
  i=$BURST
  log "run=$RUN event=burst-done"
fi
while :; do
  i=$((i+1))
  log "run=$RUN seq=$i phase=running"
  if [ "$i" = "$EXIT_AT" ]; then log "run=$RUN event=crash"; exit 3; fi
  if [ "$i" = "$LONG_AT" ]; then
    for b in $LONG_BYTES; do
      i=$((i+1))
      awk -v r="$RUN" -v s="$i" -v b="$b" 'BEGIN { pad = sprintf("%" b "s", ""); gsub(/ /, "x", pad);
        printf "run=%s seq=%d phase=long bytes=%d pad=%s\n", r, s, b, pad }' | tee -a /truth/$POD_NAME.log
    done
    log "run=$RUN event=long-done"
  fi
  if [ "$i" = "$LATE_BURST_AT" ]; then
    awk -v r="$RUN" -v s="$i" -v n="$LATE_BURST" 'BEGIN {
      for (k = s + 1; k <= s + n; k++) printf "run=%s seq=%d phase=late-burst\n", r, k }' \
      | tee -a /truth/$POD_NAME.log
    i=$((i + LATE_BURST))
    log "run=$RUN event=late-burst-done"
    if [ "$FILL_AFTER_BURST" = "1" ]; then dd if=/dev/zero of=/tmp/fill bs=1M count=60 2>/dev/null; fi
  fi
  if [ "$i" = "$FILL_AT" ]; then
    log "run=$RUN event=fill-start mb=$FILL_MB"
    dd if=/dev/zero of=/tmp/fill bs=1M count=$FILL_MB 2>/dev/null
    log "run=$RUN event=fill-done"
  fi
  if [ "$i" = "$ALLOC_AT" ]; then
    log "run=$RUN event=alloc-start mb=$ALLOC_MB"
    dd if=/dev/zero of=/mem/blob bs=1M count=$ALLOC_MB 2>/dev/null
    log "run=$RUN event=alloc-done"
  fi
  sleep $INTERVAL
done
"""


def sh(args, check=True, input_text=None, env_extra=None):
    """Run a command and return stdout; Git Bash path mangling is disabled."""
    import os

    env = dict(os.environ, MSYS_NO_PATHCONV="1", **(env_extra or {}))
    proc = subprocess.run(
        args, input=input_text, capture_output=True, text=True, env=env, timeout=180
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout + proc.stderr if proc.returncode != 0 else proc.stdout


def kubectl(*args, check=True, input_text=None):
    return sh(["kubectl", "--context", CONTEXT, *args], check=check, input_text=input_text)


def on_worker(cmd, check=False):
    return sh(["docker", "exec", WORKER, "sh", "-c", cmd], check=check)


def pod_manifest(name, run, *, interval="0.1", fill_at=0, fill_mb=0, alloc_at=0,
                 alloc_mb=0, linger=3, grace=30, eph_limit="30Mi", mem_limit="128Mi",
                 burst=0, exit_at=0, late_burst_at=0, late_burst=0, fill_after_burst=False,
                 log_grace_s=0, long_at=0, long_bytes="", cpu_request="10m", priority=None):
    env = {
        "LONG_AT": str(long_at), "LONG_BYTES": long_bytes,
        "RUN": run, "INTERVAL": interval, "FILL_AT": str(fill_at), "FILL_MB": str(fill_mb),
        "ALLOC_AT": str(alloc_at), "ALLOC_MB": str(alloc_mb), "LINGER": str(linger),
        "BURST": str(burst), "EXIT_AT": str(exit_at), "LATE_BURST_AT": str(late_burst_at),
        "LATE_BURST": str(late_burst), "FILL_AFTER_BURST": "1" if fill_after_burst else "0",
    }
    spec = {
        "nodeSelector": {"lab/role": "workload"},
        "terminationGracePeriodSeconds": grace,
        "containers": [{
            "name": "app",
            "image": "busybox:1.37.0",
            "command": ["sh", "-c", APP_SCRIPT],
            "env": [{"name": k, "value": v} for k, v in env.items()]
            + [{"name": "POD_NAME", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}}],
            # On a non-zero exit the kubelet copies the log tail into the pod status,
            # which outlives the container and its log file.
            "terminationMessagePolicy": "FallbackToLogsOnError",
            "resources": {
                "requests": {"cpu": cpu_request, "memory": "16Mi", "ephemeral-storage": "5Mi"},
                "limits": {"memory": mem_limit, "ephemeral-storage": eph_limit},
            },
            "volumeMounts": [{"name": "truth", "mountPath": "/truth"},
                             {"name": "mem", "mountPath": "/mem"}],
        }],
        "volumes": [
            {"name": "truth", "hostPath": {"path": "/var/lab-truth", "type": "DirectoryOrCreate"}},
            # tmpfs: files written here are charged as pod memory (/dev/shm is capped at 64 MB).
            {"name": "mem", "emptyDir": {"medium": "Memory", "sizeLimit": "2Gi"}},
        ],
    }
    if priority:
        spec["priorityClassName"] = priority
    if exit_at:
        spec["restartPolicy"] = "Never"
    if log_grace_s:
        # Native sidecar: the kubelet stops it only after the app container has exited, and
        # deletes the pod (and its log files) only after it exits. Sleeping on SIGTERM keeps the
        # app's log file on disk for log_grace_s after the app's last line.
        spec["initContainers"] = [{
            "name": "log-grace", "image": "busybox:1.37.0", "restartPolicy": "Always",
            "command": ["sh", "-c", f"trap 'sleep {log_grace_s}; exit 0' TERM; while :; do sleep 1; done"],
            "resources": {"requests": {"cpu": "1m", "memory": "4Mi"}},
        }]
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": {"app": "evict-demo", "run": run}},
        "spec": spec,
    }


def create_pod(manifest, wait_ready=True):
    kubectl("apply", "-f", "-", input_text=json.dumps(manifest))
    name = manifest["metadata"]["name"]
    if wait_ready:
        kubectl("-n", NAMESPACE, "wait", "--for=condition=Ready", f"pod/{name}", "--timeout=120s")
    else:
        wait_until(lambda: (get_pod(name) or {}).get("metadata", {}).get("uid"), 60, step=0.2)
    return get_pod(name)["metadata"]["uid"]


def truth_has(name, marker):
    return marker in on_worker(f"tail -c 4096 /var/lab-truth/{name}.log 2>/dev/null")


SHIPPER_DAEMONSETS = ["fluent-bit", "fluent-bit-defaults", "promtail", "promtail-static"]


def set_shippers_on_worker(enabled):
    """Take every log shipper off the worker node (or put them back) to simulate an outage."""
    patch = ({"spec": {"template": {"spec": {"affinity": None}}}} if enabled else
             {"spec": {"template": {"spec": {"affinity": {"nodeAffinity": {
                 "requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{
                     "matchExpressions": [{"key": "lab/role", "operator": "DoesNotExist"}]}]}}}}}}})
    for ds in SHIPPER_DAEMONSETS:
        kubectl("-n", "logging", "patch", "ds", ds, "--type=merge", "-p", json.dumps(patch))
    for ds in SHIPPER_DAEMONSETS:
        kubectl("-n", "logging", "rollout", "status", f"ds/{ds}", "--timeout=180s")


def kubelet_config(memory_available=None, nodefs_available=None, log_max_size=None, log_max_files=None):
    """Set the worker kubelet's eviction thresholds and log rotation, then restart it.

    Called with no arguments it restores kind's settings: disk signals at 0% (disabled), no
    memory threshold, default rotation (10Mi, 5 files).
    """
    cfg = "/var/lib/kubelet/config.yaml"
    block = (f"evictionHard:\\n  imagefs.available: 0%%\\n  nodefs.available: {nodefs_available or '0%%'}\\n"
             f"  nodefs.inodesFree: 0%%\\n")
    if memory_available:
        block += f"  memory.available: {memory_available}\\n"
    if log_max_size:
        block += f"containerLogMaxSize: {log_max_size}\\n"
    if log_max_files:
        block += f"containerLogMaxFiles: {log_max_files}\\n"
    on_worker(f"sed -i '/^evictionHard:/,/^[^ ]/{{/^  /d}}; /^evictionHard:/d; /^containerLogMax/d' {cfg} && "
              f"printf '{block}' >> {cfg}", check=True)
    on_worker("systemctl restart kubelet", check=True)
    time.sleep(3)
    wait_until(lambda: "True" in kubectl("get", "node", WORKER, "-o",
               "jsonpath={.status.conditions[?(@.type=='Ready')].status}", check=False), 60)


def node_available_mi(resource):
    """memory or fs (nodefs) availability as the worker kubelet computes it, in MiB."""
    summary = json.loads(kubectl("get", "--raw", f"/api/v1/nodes/{WORKER}/proxy/stats/summary"))
    return summary["node"][resource]["availableBytes"] // (1024 * 1024)


def pause_loki(paused):
    """Freeze or thaw the Loki/Grafana container: every shipper's pushes stall while frozen."""
    sh(["docker", "pause" if paused else "unpause", "evict-lgtm"], check=False)


def proof_open_deleted_files():
    """Files the fb-proof Fluent Bit still holds open after they were deleted from the node."""
    return on_worker("for p in $(pgrep -f proof.yaml); do ls -l /proc/$p/fd 2>/dev/null; done "
                     "| grep -o '/var/log/[^ ]*(deleted)' | sed 's#.*/var/log/pods/##' | sort -u").split()


def processes_holding_deleted_logs():
    """Which processes on the worker still have a deleted /var/log/pods file open, and how many."""
    return on_worker(
        "for p in /proc/[0-9]*; do n=$(ls -l $p/fd 2>/dev/null | grep -c '/var/log/pods/.*(deleted)'); "
        "[ \"$n\" -gt 0 ] && echo \"$(cat $p/comm)=$n\"; done | sort").split()


def proof_log_events(since="5m"):
    out = kubectl("-n", "logging", "logs", "ds/fluent-bit-proof", f"--since={since}", check=False)
    return [line[:200] for line in out.splitlines() if re.search(r"paused|resume|deleted|rotat", line)]


def get_pod(name):
    out = kubectl("-n", NAMESPACE, "get", "pod", name, "-o", "json", check=False)
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def api_evict(name):
    """Eviction API: what kubectl drain, cluster-autoscaler and Karpenter call."""
    body = {"apiVersion": "policy/v1", "kind": "Eviction",
            "metadata": {"name": name, "namespace": NAMESPACE}}
    kubectl("create", "--raw", f"/api/v1/namespaces/{NAMESPACE}/pods/{name}/eviction",
            "-f", "-", input_text=json.dumps(body))


def pod_state(name):
    pod = get_pod(name)
    if not pod:
        return {"exists": False}
    status = pod.get("status", {})
    cs = (status.get("containerStatuses") or [{}])[0]
    term = cs.get("state", {}).get("terminated") or cs.get("lastState", {}).get("terminated") or {}
    return {
        "exists": True,
        "phase": status.get("phase"),
        "reason": status.get("reason"),
        "message": status.get("message"),
        "deleting": bool(pod["metadata"].get("deletionTimestamp")),
        "exit_code": term.get("exitCode"),
        "term_reason": term.get("reason"),
        "term_message_tail": (term.get("message") or "").strip().splitlines()[-3:],
        "container_id": cs.get("containerID"),
    }


def node_files(uid):
    out = on_worker(f"find /var/log/pods -path '*{uid}*' -name '*.log*' 2>/dev/null | wc -l; "
                    f"ls -d /var/log/pods/*{uid}* 2>/dev/null | wc -l").split()
    files, dirs = (out + ["0", "0"])[:2]
    return f"pod dir {'present' if dirs != '0' else 'GONE'}, {files} log file(s)"


def kubectl_logs(name):
    out = kubectl("-n", NAMESPACE, "logs", name, "--tail=1000", check=False)
    seqs = SEQ.findall(out)
    if seqs:
        return f"ok, {len(seqs)} seq lines (last seq={seqs[-1]})"
    return "FAILED: " + out.strip().splitlines()[-1][:160] if out.strip() else "empty"


def observe(name, uid, label, notes):
    entry = {
        "t": label,
        "pod": pod_state(name),
        "kubectl_logs": kubectl_logs(name),
        "node_files": node_files(uid),
    }
    notes.append(entry)
    print(f"  [{label}] pod={entry['pod']} logs={entry['kubectl_logs']} files={entry['node_files']}")


def watch_changes(name, uid, notes, seconds, step=2.0):
    """Observe repeatedly after an eviction, recording only when something changes."""
    began, last = time.time(), None
    while time.time() - began < seconds:
        pod = pod_state(name)
        snapshot = (pod.get("exists"), pod.get("term_reason"), kubectl_logs(name)[:40], node_files(uid))
        if snapshot != last:
            observe(name, uid, f"evicted+{time.time() - began:.0f}s", notes)
            last = snapshot
        time.sleep(step)


def wait_until(predicate, timeout, step=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(step)
    return False


def loki_query(query, start_ns, limit=5000):
    """Fetch all lines for a query, paginating forward from start_ns."""
    results = []
    cursor = start_ns
    end_ns = time.time_ns()
    while True:
        params = urllib.parse.urlencode({
            "query": query, "start": cursor, "end": end_ns, "limit": limit, "direction": "forward",
        })
        with urllib.request.urlopen(f"{LOKI}/loki/api/v1/query_range?{params}", timeout=30) as resp:
            data = json.load(resp)["data"]["result"]
        batch = [(int(ts), line, stream["stream"]) for stream in data for ts, line in stream["values"]]
        results.extend(batch)
        if len(batch) < limit:
            return results
        cursor = max(ts for ts, _, _ in batch) + 1


def worker_running():
    return sh(["docker", "inspect", "-f", "{{.State.Running}}", WORKER], check=False).strip() == "true"


def truth_lines(name):
    if worker_running():
        return on_worker(f"cat /var/lab-truth/{name}.log 2>/dev/null").splitlines()
    # docker cp reads a stopped container's filesystem: the ground truth outlives the "crash".
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        sh(["docker", "cp", f"{WORKER}:/var/lab-truth/{name}.log", tmp], check=False)
        path = Path(tmp) / f"{name}.log"
        return path.read_text().splitlines() if path.exists() else []


SEQ = re.compile(r"(?<![_\w])seq=(\d+)")


def seq_set(lines):
    return {int(m.group(1)) for line in lines if (m := SEQ.search(line))}


def ranges(nums):
    nums = sorted(nums)
    out, start, prev = [], None, None
    for n in nums:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            out.append(f"{start}-{prev}" if start != prev else str(start))
            start = prev = n
    if start is not None:
        out.append(f"{start}-{prev}" if start != prev else str(start))
    return out


def score(name, run, start_ns):
    truth = truth_lines(name)
    truth_seqs = seq_set(truth)
    truth_events = [m.group(1) for line in truth if (m := re.search(r"event=(\S+)", line))]
    rows = {}
    for shipper, selector in SHIPPERS.items():
        # The pod-lifecycle watcher quotes the pod's last lines; it must not count as delivery.
        # An absent container label still matches !=, so lines that lost metadata are kept.
        got = loki_query(f'{selector} |= "run={run} "', start_ns)
        lines = [line for _, line, _ in got]
        seqs = seq_set(lines)
        all_seq_lines = [line for line in lines if SEQ.search(line)]
        label_sets = {json.dumps({k: v for k, v in s.items() if k in LABEL_KEYS}, sort_keys=True)
                      for _, _, s in got}
        missing = truth_seqs - seqs
        rows[shipper] = {
            "lines": len(lines),
            "unique_seq": len(seqs),
            "duplicates": len(all_seq_lines) - len(seqs),
            "missing": len(missing),
            "missing_ranges": ranges(missing)[:6],
            "events": [m.group(1) for line in lines if (m := re.search(r"event=(\S+)", line))],
            "label_sets": sorted(label_sets),
            # Long lines: delivered length per seq, to catch truncation or splitting.
            "long_lines": {m.group(1): len(line) for line in lines
                           if "phase=long" in line and (m := SEQ.search(line))},
        }
    events = loki_query(f'{{job="k8s-events", namespace="{NAMESPACE}"}} |= "{name}"', start_ns)
    event_summary = []
    # The Loki output moves keys used as labels (reason, kind, namespace) out of the body.
    for ts, line, stream in sorted(events):
        try:
            message = json.loads(line).get("message") or ""
        except json.JSONDecodeError:
            message = line
        event_summary.append(f"{stream.get('reason')}: {message[:150]}")
    truth_long = {m.group(1): len(line) for line in truth if "phase=long" in line and (m := SEQ.search(line))}
    return {"truth_seq": len(truth_seqs), "truth_events": truth_events, "truth_long_lines": truth_long,
            "shippers": rows, "k8s_events": event_summary}


# --- scenarios -------------------------------------------------------------

SCENARIOS = {}


def scenario(fn):
    SCENARIOS[fn.__name__.replace("_", "-")] = fn
    return fn


@scenario
def kubelet_ephemeral(name, run, notes):
    """Kubelet evicts a pod that exceeds its ephemeral-storage limit (pod stays as Failed/Evicted)."""
    uid = create_pod(pod_manifest(name, run, fill_at=100, fill_mb=60))
    observe(name, uid, "running", notes)
    wait_until(lambda: pod_state(name).get("reason") == "Evicted", 90, step=0.5)
    watch_changes(name, uid, notes, 60)
    return uid


@scenario
def api_eviction(name, run, notes):
    """Eviction API (kubectl drain / autoscaler): graceful SIGTERM, then the pod object is deleted."""
    uid = create_pod(pod_manifest(name, run, linger=5))
    time.sleep(10)
    observe(name, uid, "running", notes)
    api_evict(name)
    time.sleep(2)
    observe(name, uid, "evict+2s", notes)
    wait_until(lambda: not get_pod(name), 60)
    observe(name, uid, "pod-deleted", notes)
    time.sleep(3)
    observe(name, uid, "deleted+3s", notes)
    return uid


@scenario
def api_eviction_fast(name, run, notes):
    """Pod evicted ~1s after it becomes Ready, with no grace period: tests shipper discovery latency."""
    uid = create_pod(pod_manifest(name, run, linger=0, grace=0, interval="0.02"))
    time.sleep(1)
    api_evict(name)
    wait_until(lambda: not get_pod(name), 60, step=0.2)
    observe(name, uid, "pod-deleted", notes)
    return uid


@scenario
def kubelet_ephemeral_fast(name, run, notes):
    """Ephemeral-storage eviction right after start; the pod object stays, so files stay too."""
    uid = create_pod(pod_manifest(name, run, fill_at=5, fill_mb=60, interval="0.02"))
    wait_until(lambda: pod_state(name).get("reason") == "Evicted", 90, step=0.5)
    watch_changes(name, uid, notes, 60)
    return uid


@scenario
def control_crash(name, run, notes):
    """Control: the container crashes on its own (no eviction). Logs should stay retrievable."""
    uid = create_pod(pod_manifest(name, run, exit_at=100))
    wait_until(lambda: pod_state(name).get("phase") == "Failed", 60, step=0.5)
    watch_changes(name, uid, notes, 30)
    return uid


@scenario
def api_eviction_slow(name, run, notes):
    """Pod lives ~90s before an API eviction: long enough for a 60s refresh_interval to find it."""
    uid = create_pod(pod_manifest(name, run, linger=3, interval="0.2"))
    time.sleep(90)
    api_evict(name)
    wait_until(lambda: not get_pod(name), 60)
    observe(name, uid, "pod-deleted", notes)
    return uid


@scenario
def log_burst_kubelet(name, run, notes):
    """Pod logs ~45 MB in a burst; its own log files push it over the ephemeral-storage limit."""
    uid = create_pod(pod_manifest(name, run, burst=300000, eph_limit="40Mi"), wait_ready=False)
    wait_until(lambda: pod_state(name).get("reason") == "Evicted", 180, step=0.5)
    watch_changes(name, uid, notes, 40)
    return uid


@scenario
def log_burst_api(name, run, notes):
    """Pod logs ~15 MB in a burst and is API-evicted with no grace the moment the burst ends."""
    uid = create_pod(pod_manifest(name, run, burst=100000, grace=0, linger=0, eph_limit="1Gi"),
                     wait_ready=False)
    wait_until(lambda: truth_has(name, "event=burst-done"), 120, step=0.2)
    api_evict(name)
    wait_until(lambda: not get_pod(name), 60, step=0.2)
    observe(name, uid, "pod-deleted", notes)
    return uid


@scenario
def log_burst_api_grace(name, run, notes):
    """log-burst-api plus a native sidecar that holds the pod (and its log files) 5s after the app exits."""
    uid = create_pod(pod_manifest(name, run, burst=100000, grace=15, linger=0, eph_limit="1Gi",
                                  log_grace_s=5), wait_ready=False)
    wait_until(lambda: truth_has(name, "event=burst-done"), 120, step=0.2)
    api_evict(name)
    wait_until(lambda: not get_pod(name), 60, step=0.2)
    observe(name, uid, "pod-deleted", notes)
    return uid


@scenario
def shipper_outage_kubelet(name, run, notes):
    """Shippers are down on the node while the kubelet evicts a pod; they return 30s later."""
    set_shippers_on_worker(False)
    try:
        uid = create_pod(pod_manifest(name, run, fill_at=100, fill_mb=60))
        wait_until(lambda: pod_state(name).get("reason") == "Evicted", 90, step=0.5)
        observe(name, uid, "evicted+0s", notes)
        time.sleep(30)
        observe(name, uid, "evicted+30s (shippers return)", notes)
    finally:
        set_shippers_on_worker(True)
    return uid


@scenario
def node_memory_pressure(name, run, notes):
    """Node-pressure eviction: memory.available threshold set just below current, pod allocates past it."""
    uid = create_pod(pod_manifest(name, run, mem_limit="3Gi", alloc_at=150, alloc_mb=1500))
    try:
        available = node_available_mi("memory")
        threshold = max(available - 600, 200)
        print(f"  node memory.available={available}Mi -> evictionHard memory.available={threshold}Mi")
        kubelet_config(memory_available=f"{threshold}Mi")
        observe(name, uid, "threshold-set", notes)
        wait_until(lambda: pod_state(name).get("reason") == "Evicted", 120, step=0.5)
        watch_changes(name, uid, notes, 40)
    finally:
        kubelet_config()
    return uid


def loki_has(shipper, run):
    params = urllib.parse.urlencode({"query": f'{SHIPPERS[shipper]} |= "run={run} "',
                                     "limit": 1, "start": time.time_ns() - 10 * 60 * 10**9})
    with urllib.request.urlopen(f"{LOKI}/loki/api/v1/query_range?{params}", timeout=30) as resp:
        return bool(json.load(resp)["data"]["result"])


def late_burst(name, run, notes, lines, kubelet):
    """Run until even the 60s-refresh shipper is tailing the file, then burst and get evicted at once."""
    # 1 line/s; the burst fires at seq 80, by which point fluent-bit-defaults must have the file.
    uid = create_pod(pod_manifest(name, run, interval="1", linger=0, grace=0, late_burst_at=80,
                                  late_burst=lines, fill_after_burst=kubelet, eph_limit="40Mi"))
    found = wait_until(lambda: loki_has("fluent-bit-defaults", run), 75, step=2)
    print(f"  fluent-bit-defaults tailing the file before the burst: {found}")
    if kubelet:
        wait_until(lambda: pod_state(name).get("reason") == "Evicted", 150, step=0.5)
    else:
        wait_until(lambda: truth_has(name, "event=late-burst-done"), 150, step=0.1)
        api_evict(name)
        wait_until(lambda: not get_pod(name), 60, step=0.2)
    observe(name, uid, "evicted", notes)
    return uid


@scenario
def late_burst_api_15(name, run, notes):
    """Known pod writes its last 15 lines in one go and is API-evicted with no grace immediately."""
    return late_burst(name, run, notes, 15, kubelet=False)


@scenario
def late_burst_api_20k(name, run, notes):
    """Known pod writes its last 20,000 lines (~1 MB) in one go and is API-evicted immediately."""
    return late_burst(name, run, notes, 20000, kubelet=False)


@scenario
def late_burst_kubelet_20k(name, run, notes):
    """Known pod writes 20,000 lines, then breaks its ephemeral-storage limit (kubelet eviction)."""
    return late_burst(name, run, notes, 20000, kubelet=True)


# --- edge cases ------------------------------------------------------------

@scenario
def api_eviction_fast_grace(name, run, notes):
    """api-eviction-fast plus a 12s log-grace sidecar: longer than fb-proof's 10s refresh_interval."""
    uid = create_pod(pod_manifest(name, run, linger=0, grace=20, interval="0.02", log_grace_s=12))
    time.sleep(1)
    api_evict(name)
    wait_until(lambda: not get_pod(name), 60, step=0.2)
    observe(name, uid, "pod-deleted", notes)
    return uid


def paused_drain(name, run, notes, lines, kubelet_overrides=None):
    """Loki frozen while a known pod bursts and is evicted: the file is deleted while shippers are behind."""
    if kubelet_overrides:
        kubelet_config(**kubelet_overrides)
    try:
        uid = create_pod(pod_manifest(name, run, interval="1", linger=0, grace=0, late_burst_at=40,
                                      late_burst=lines, eph_limit="1Gi"))
        found = wait_until(lambda: loki_has("fb-proof", run), 60, step=2)
        print(f"  fb-proof tailing the file before Loki is frozen: {found}")
        pause_loki(True)
        try:
            wait_until(lambda: truth_has(name, "event=late-burst-done"), 120, step=0.2)
            time.sleep(3)  # let the kubelet rotate if rotation is configured
            api_evict(name)
            wait_until(lambda: not get_pod(name), 60, step=0.2)
            observe(name, uid, "pod-deleted (Loki frozen)", notes)
            held = proof_open_deleted_files()
            notes.append({"t": "fb-proof open deleted files", "files": held})
            print(f"  fb-proof still holds {len(held)} deleted file(s) open: {held}")
            time.sleep(10)
        finally:
            pause_loki(False)
        print("  Loki thawed; waiting 45s for retries to drain")
        time.sleep(45)
        events = proof_log_events()
        notes.append({"t": "fb-proof log", "lines": events})
        for line in events[-6:]:
            print(f"    fb-proof: {line}")
    finally:
        if kubelet_overrides:
            kubelet_config()
    return uid


@scenario
def paused_drain_api(name, run, notes):
    """Loki frozen; a known pod writes 20k lines and is API-evicted. Can shippers finish a deleted file?"""
    return paused_drain(name, run, notes, 20000)


@scenario
def rotation_paused_drain(name, run, notes):
    """As paused-drain-api but 80k lines (~5 MB) with kubelet rotation at 1Mi keeping 2 files."""
    return paused_drain(name, run, notes, 80000, {"log_max_size": "1Mi", "log_max_files": 2})


@scenario
def slow_reader_drain(name, run, notes):
    """45 MB burst + kubelet eviction while fb-proof is CPU-throttled: does it read the deleted file?"""
    uid = create_pod(pod_manifest(name, run, burst=300000, eph_limit="40Mi"), wait_ready=False)
    wait_until(lambda: pod_state(name).get("reason") == "Evicted", 180, step=0.5)
    for label, delay in (("evicted+5s", 5), ("evicted+20s", 15), ("evicted+60s", 40), ("evicted+120s", 60)):
        time.sleep(delay)
        held = processes_holding_deleted_logs()
        notes.append({"t": f"{label} processes holding deleted pod logs", "holders": held})
        print(f"  [{label}] node files: {node_files(uid)}; holding deleted pod logs: {held}")
    time.sleep(60)  # throttled readers need time to finish
    return uid


@scenario
def long_lines_api(name, run, notes):
    """A known pod writes a 100 KB and a 1 MB line (CRI splits at 16 KB), then is API-evicted at once."""
    uid = create_pod(pod_manifest(name, run, interval="0.5", linger=0, grace=0, long_at=30,
                                  long_bytes="100000 1000000", eph_limit="1Gi"))
    wait_until(lambda: truth_has(name, "event=long-done"), 90, step=0.2)
    api_evict(name)
    wait_until(lambda: not get_pod(name), 60, step=0.2)
    observe(name, uid, "pod-deleted", notes)
    return uid


@scenario
def force_delete(name, run, notes):
    """kubectl delete --grace-period=0 --force: the pod object vanishes while the container still runs."""
    uid = create_pod(pod_manifest(name, run, interval="0.05", linger=5))
    time.sleep(10)
    kubectl("-n", NAMESPACE, "delete", "pod", name, "--grace-period=0", "--force", check=False)
    observe(name, uid, "force-deleted", notes)
    time.sleep(8)
    observe(name, uid, "force-deleted+8s", notes)
    return uid


ALL_SHIPPER_DAEMONSETS = ["fluent-bit", "fluent-bit-defaults", "fluent-bit-proof", "promtail",
                          "promtail-static", "alloy", "otel-filelog", "vector", "fluent-bit-keep",
                          "fluent-bit-agg-agent"]


@scenario
def shipper_restart(name, run, notes):
    """Every shipper is restarted while the pod logs 20 lines/s; checks for gaps and duplicates."""
    uid = create_pod(pod_manifest(name, run, interval="0.05", linger=3))
    time.sleep(15)
    for ds in ALL_SHIPPER_DAEMONSETS:
        kubectl("-n", "logging", "rollout", "restart", f"ds/{ds}")
    for ds in ALL_SHIPPER_DAEMONSETS:
        kubectl("-n", "logging", "rollout", "status", f"ds/{ds}", "--timeout=240s")
    observe(name, uid, "shippers restarted", notes)
    time.sleep(15)
    api_evict(name)
    wait_until(lambda: not get_pod(name), 60, step=0.2)
    return uid


@scenario
def node_disk_pressure(name, run, notes):
    """Node-pressure eviction on disk (nodefs threshold just below current), plus a crashed bystander pod."""
    bystander = f"bystander-{run}"
    by_uid = create_pod(pod_manifest(bystander, run + "b", exit_at=50))
    wait_until(lambda: pod_state(bystander).get("phase") == "Failed", 60, step=0.5)
    uid = create_pod(pod_manifest(name, run, fill_at=150, fill_mb=3000, eph_limit="20Gi"))
    try:
        available = node_available_mi("fs")
        threshold = available - 1500
        print(f"  node fs available={available}Mi -> evictionHard nodefs.available={threshold}Mi")
        kubelet_config(nodefs_available=f"{threshold}Mi")
        observe(bystander, by_uid, "bystander before pressure", notes)
        wait_until(lambda: pod_state(name).get("reason") == "Evicted", 180, step=0.5)
        watch_changes(name, uid, notes, 30)
        observe(bystander, by_uid, "bystander after pressure", notes)
        events = kubectl("get", "events", "-A", "--field-selector", f"involvedObject.name={WORKER}",
                         "-o", "jsonpath={range .items[*]}{.reason}: {.message}{\"\\n\"}{end}", check=False)
        notes.append({"t": "node events", "lines": events.splitlines()[-10:]})
        print("  node events:", *events.splitlines()[-6:], sep="\n    ")
    finally:
        kubelet_config()
        kubectl("-n", NAMESPACE, "delete", "pod", bystander, "--wait=false", check=False)
    return uid


@scenario
def preemption(name, run, notes):
    """The scheduler preempts the pod for a higher-priority one (graceful delete, not the Eviction API)."""
    kubectl("apply", "-f", "-", input_text=json.dumps({
        "apiVersion": "scheduling.k8s.io/v1", "kind": "PriorityClass",
        "metadata": {"name": "lab-high"}, "value": 1000000}))
    allocatable = kubectl("get", "node", WORKER, "-o", "jsonpath={.status.allocatable.cpu}")
    big = f"{int(int(allocatable) * 0.7 * 1000)}m"
    uid = create_pod(pod_manifest(name, run, linger=3, cpu_request=big))
    time.sleep(8)
    high = pod_manifest(f"high-{run}", run + "h", cpu_request=big, priority="lab-high")
    kubectl("apply", "-f", "-", input_text=json.dumps(high))
    wait_until(lambda: not get_pod(name), 90, step=0.5)
    observe(name, uid, "preempted", notes)
    kubectl("-n", NAMESPACE, "delete", "pod", f"high-{run}", "--wait=false", check=False)
    return uid


@scenario
def taint_eviction(name, run, notes):
    """A NoExecute taint on the node: the taint manager deletes pods that do not tolerate it."""
    uid = create_pod(pod_manifest(name, run, linger=3))
    time.sleep(8)
    kubectl("taint", "node", WORKER, "lab/evict=now:NoExecute")
    try:
        wait_until(lambda: not get_pod(name), 90, step=0.5)
        observe(name, uid, "taint-evicted", notes)
    finally:
        kubectl("taint", "node", WORKER, "lab/evict=now:NoExecute-", check=False)
    return uid


# --- residual gaps -----------------------------------------------------------

@scenario
def force_delete_short(name, run, notes):
    """Pod force-deleted (--grace-period=0 --force) ~1s after Ready: no grace, no sidecar can help."""
    uid = create_pod(pod_manifest(name, run, linger=0, grace=0, interval="0.02", log_grace_s=12))
    time.sleep(1)
    kubectl("-n", NAMESPACE, "delete", "pod", name, "--grace-period=0", "--force", check=False)
    time.sleep(10)
    observe(name, uid, "force-deleted+10s", notes)
    return uid


@scenario
def restart_while_behind(name, run, notes):
    """45 MB burst + kubelet eviction while shippers are behind, then every shipper is restarted.

    Meaningful only with shippers CPU-limited beforehand (see README).
    """
    uid = create_pod(pod_manifest(name, run, burst=300000, eph_limit="40Mi"), wait_ready=False)
    wait_until(lambda: pod_state(name).get("reason") == "Evicted", 180, step=0.5)
    time.sleep(10)
    notes.append({"t": "before restart: holding deleted pod logs", "holders": processes_holding_deleted_logs()})
    for ds in ALL_SHIPPER_DAEMONSETS:
        kubectl("-n", "logging", "rollout", "restart", f"ds/{ds}")
    for ds in ALL_SHIPPER_DAEMONSETS:
        kubectl("-n", "logging", "rollout", "status", f"ds/{ds}", "--timeout=300s")
    observe(name, uid, "shippers restarted", notes)
    time.sleep(240)  # CPU-limited shippers need minutes for 45 MB
    return uid


def crash_worker(name, run, notes, loki_down_s):
    """Kill the worker node container outright, score while it is down, then boot it and score again."""
    uid = create_pod(pod_manifest(name, run, interval="0.01", linger=0))
    time.sleep(20)
    if loki_down_s:
        pause_loki(True)
        time.sleep(loki_down_s)
    sh(["docker", "kill", WORKER], check=True)
    killed_at = time.time()
    print(f"  worker killed{' with Loki frozen ' + str(loki_down_s) + 's' if loki_down_s else ''}")
    if loki_down_s:
        time.sleep(3)
        pause_loki(False)
    time.sleep(40)  # aggregator and Loki drain what reached them
    down = score(name, run, int(killed_at - 120) * 10**9)
    notes.append({"t": "node down (spot loss)", "score": down})
    print("  -- while the node is gone (nothing on it can be recovered):")
    print_report({**down, "pod": name})
    sh(["docker", "start", WORKER], check=True)
    wait_until(lambda: "True" in kubectl("get", "node", WORKER, "-o",
               "jsonpath={.status.conditions[?(@.type=='Ready')].status}", check=False), 240, step=3)
    print("  worker back; waiting 120s for shippers to restart and resume")
    time.sleep(120)
    return uid


@scenario
def node_crash(name, run, notes):
    """Worker node killed mid-logging (power cut). Scored while down, then again after it reboots."""
    return crash_worker(name, run, notes, 0)


@scenario
def node_crash_loki_down(name, run, notes):
    """As node-crash, but Loki was unreachable for 20s first, so agents hold a backlog on the node."""
    return crash_worker(name, run, notes, 20)


def run_scenario(key, keep):
    run = uuid.uuid4().hex[:8]
    name = f"{key}-{run}"[:63]
    print(f"== scenario {key}  run={run}  pod={name}")
    print(f"   {SCENARIOS[key].__doc__}")
    start_ns = time.time_ns() - 5 * 10**9
    notes = []
    uid = SCENARIOS[key](name, run, notes)
    print("  waiting 15s for shippers to flush...")
    time.sleep(15)
    report = score(name, run, start_ns)
    report.update({"scenario": key, "run": run, "pod": name, "uid": uid, "observations": notes,
                   "at": datetime.now(timezone.utc).isoformat()})
    print_report(report)
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"{key}-{run}.json").write_text(json.dumps(report, indent=2))
    if not keep:
        kubectl("-n", NAMESPACE, "delete", "pod", name, "--ignore-not-found", "--wait=false", check=False)
    return report


def print_report(r):
    print(f"\n  ground truth: {r['truth_seq']} seq lines, events={r['truth_events']}")
    print(f"  {'shipper':16} {'lines':>6} {'uniq':>6} {'dup':>4} {'missing':>8}  missing ranges / events / labels")
    for shipper, s in r["shippers"].items():
        print(f"  {shipper:16} {s['lines']:6} {s['unique_seq']:6} {s['duplicates']:4} {s['missing']:8}"
              f"  {s['missing_ranges']} {s['events']}")
        for ls in s["label_sets"]:
            print(f"  {'':16} labels {ls}")
    print("  k8s events from Loki:")
    for ev in r["k8s_events"]:
        print(f"    - {ev}")


def print_summary(key, reports):
    print(f"\n#### {key}: {len(reports)} run(s)")
    print(f"  {'shipper':20} {'complete runs':>14} {'lines missing (all runs)':>26} {'runs missing exit/SIGTERM':>27}")
    for shipper in SHIPPERS:
        if any(shipper not in r["shippers"] for r in reports):
            continue  # saved before this shipper joined the lab
        rows = [r["shippers"][shipper] for r in reports]
        complete = sum(1 for s in rows if s["missing"] == 0)
        missing = sum(s["missing"] for s in rows)
        no_tail = sum(1 for r, s in zip(reports, rows)
                      if set(r["truth_events"]) & {"SIGTERM", "exit"} - set(s["events"]))
        total = sum(r["truth_seq"] for r in reports)
        print(f"  {shipper:20} {complete:>8}/{len(rows):<5} {missing:>12} of {total:<11} {no_tail:>16}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    run_p = sub.add_parser("run")
    run_p.add_argument("scenario", nargs="+", choices=sorted(SCENARIOS))
    run_p.add_argument("--keep", action="store_true", help="leave the pod in place afterwards")
    run_p.add_argument("--repeat", type=int, default=1)
    sub.add_parser("list")
    rescore_p = sub.add_parser("rescore", help="recompute saved results against Loki and the node's ground truth")
    rescore_p.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    if args.cmd == "list":
        for key, fn in SCENARIOS.items():
            print(f"{key:24} {fn.__doc__}")
        return
    if args.cmd == "rescore":
        by_scenario = {}
        for path in args.files:
            saved = json.loads(path.read_text())
            start_ns = int(datetime.fromisoformat(saved["at"]).timestamp() - 600) * 10**9
            saved.update(score(saved["pod"], saved["run"], start_ns))
            path.write_text(json.dumps(saved, indent=2))
            by_scenario.setdefault(saved["scenario"], []).append(saved)
        for key, reports in by_scenario.items():
            print_summary(key, reports)
        return
    summaries = {key: [run_scenario(key, args.keep) for _ in range(args.repeat)]
                 for key in args.scenario}
    for key, reports in summaries.items():
        print_summary(key, reports)


if __name__ == "__main__":
    sys.exit(main())
