"""Measure what Fluent Bit's tail refresh_interval costs in CPU.

Three Fluent Bit pods on the worker, identical except for refresh_interval,
tail the same directory of N log files (output: null, so only the input side
is measured). One file in ten gets a line per second so the inotify path is
exercised too. CPU comes from containerd (crictl stats) as the difference
between two samples.

Usage: python bench/refresh_cost.py [--files 100 1000] [--seconds 120]
"""

import argparse
import json
import os
import subprocess
import time

CONTEXT = "kind-evict-lab"
NAMESPACE = "bench"
WORKER = "evict-lab-worker"
INTERVALS = [1, 10, 60]
BENCH_DIR = "/var/log/bench"
WRITER_PID = "/run/bench-writer.pid"
ENV = dict(os.environ, MSYS_NO_PATHCONV="1")


def run(*args, stdin=None, check=True):
    return subprocess.run(args, input=stdin, capture_output=True, text=True, env=ENV, check=check).stdout


def kubectl(*args, stdin=None):
    return run("kubectl", "--context", CONTEXT, *args, stdin=stdin)


def on_worker(cmd):
    return run("docker", "exec", WORKER, "sh", "-c", cmd)


def manifests():
    docs = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NAMESPACE}}]
    for interval in INTERVALS:
        name = f"fb-refresh-{interval}"
        config = (
            "service:\n  flush: 1\n  log_level: warn\n"
            "pipeline:\n  inputs:\n    - name: tail\n"
            f"      path: {BENCH_DIR}/*.log\n      refresh_interval: {interval}\n"
            "      read_from_head: true\n"
            "  outputs:\n    - name: 'null'\n      match: '*'\n"
        )
        docs.append({"apiVersion": "v1", "kind": "ConfigMap",
                     "metadata": {"name": name, "namespace": NAMESPACE},
                     "data": {"fluent-bit.yaml": config}})
        docs.append({
            "apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": name, "namespace": NAMESPACE},
            "spec": {
                "nodeSelector": {"lab/role": "workload"},
                "containers": [{
                    "name": "fluent-bit", "image": "fluent/fluent-bit:5.1.5",
                    "args": ["-c", "/conf/fluent-bit.yaml"],
                    "volumeMounts": [{"name": "bench", "mountPath": BENCH_DIR, "readOnly": True},
                                     {"name": "conf", "mountPath": "/conf"}],
                }],
                "volumes": [{"name": "bench", "hostPath": {"path": BENCH_DIR, "type": "DirectoryOrCreate"}},
                            {"name": "conf", "configMap": {"name": name}}],
            },
        })
    return {"apiVersion": "v1", "kind": "List", "items": docs}


def set_files(count):
    """Create exactly `count` files in the bench dir; keep an existing writer loop running."""
    on_worker(f"mkdir -p {BENCH_DIR} && cd {BENCH_DIR} && rm -f *.log && "
              f"for i in $(seq 1 {count}); do echo start > f$i.log; done")


def start_writers(count):
    # Every tenth file gets a line per second: steady inotify traffic, like a node with busy pods.
    script = (f"while :; do for i in $(seq 1 10 {count}); do echo tick >> {BENCH_DIR}/f$i.log; done; "
              f"sleep 1; done\n")
    run("docker", "exec", "-i", WORKER, "sh", "-c", "cat > /usr/local/bin/bench-writer.sh", stdin=script)
    stop_writers()
    on_worker(f"nohup sh /usr/local/bin/bench-writer.sh >/dev/null 2>&1 & echo $! > {WRITER_PID}")


def stop_writers():
    # A pid file, not pkill -f: the pattern would also match the shell running pkill.
    on_worker(f"[ -f {WRITER_PID} ] && kill $(cat {WRITER_PID}) 2>/dev/null; rm -f {WRITER_PID}; true")


def cpu_ns():
    stats = json.loads(on_worker("crictl stats -o json"))["stats"]
    out = {}
    for s in stats:
        labels = s["attributes"]["labels"]
        if labels.get("io.kubernetes.pod.namespace") == NAMESPACE:
            out[labels["io.kubernetes.pod.name"]] = int(s["cpu"]["usageCoreNanoSeconds"]["value"])
    return out


def measure(seconds):
    before, t0 = cpu_ns(), time.time()
    time.sleep(seconds)
    after, t1 = cpu_ns(), time.time()
    return {pod: (after[pod] - before[pod]) / (t1 - t0) / 1e6 for pod in before}  # millicores


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", type=int, nargs="+", default=[100, 1000])
    parser.add_argument("--seconds", type=int, default=120)
    args = parser.parse_args()

    kubectl("apply", "-f", "-", stdin=json.dumps(manifests()))
    kubectl("-n", NAMESPACE, "wait", "--for=condition=Ready", "pod", "--all", "--timeout=180s")
    results = {}
    try:
        for count in args.files:
            set_files(count)
            start_writers(count)
            time.sleep(70)  # every instance has rescanned at least once and settled
            results[count] = measure(args.seconds)
            print(f"{count} files: " + ", ".join(
                f"refresh {i}s = {results[count][f'fb-refresh-{i}']:.1f} mCPU" for i in INTERVALS), flush=True)
    finally:
        stop_writers()
        on_worker(f"rm -rf {BENCH_DIR} /usr/local/bin/bench-writer.sh")
        kubectl("delete", "namespace", NAMESPACE, "--wait=false")
    return results


if __name__ == "__main__":
    main()
