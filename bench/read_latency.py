"""Separate Fluent Bit's discovery delay from its read latency.

The test pod writes a line only when the harness drops a trigger file on the
node, so both ends of each measurement are on this machine's clock:

  discovery delay  pod start -> first line seen in Loki (new file must be found by the glob scan)
  read latency     trigger   -> line seen in Loki (file already tailed)

If reading were timer-driven, read latency would grow with refresh_interval.

Usage: python bench/read_latency.py [--samples 10]
"""

import argparse
import json
import random
import sys
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import lab  # noqa: E402  (shared kubectl/Loki helpers)

INSTANCES = {"fluent-bit": 1, "fb-proof": 10, "fluent-bit-defaults": 60}  # shipper -> refresh_interval

POD_SCRIPT = r"""
echo "latency run=$RUN n=0 started"
n=0
while :; do
  if [ -f /truth/trigger-$RUN ]; then
    rm -f /truth/trigger-$RUN
    n=$((n+1))
    echo "latency run=$RUN n=$n"
  fi
  sleep 0.05
done
"""


def seen(shipper, run, n):
    query = f'{{shipper="{shipper}"}} |= "latency run={run} n={n}"'
    params = urllib.parse.urlencode({"query": query, "limit": 1,
                                     "start": time.time_ns() - 15 * 60 * 10**9})
    with urllib.request.urlopen(f"{lab.LOKI}/loki/api/v1/query_range?{params}", timeout=10) as resp:
        return bool(json.load(resp)["data"]["result"])


def wait_seen(run, n, since, timeout):
    """Poll Loki every 100ms; return seconds from `since` until each shipper has line n."""
    pending, out = set(INSTANCES), {}
    while pending and time.time() - since < timeout:
        for shipper in list(pending):
            if seen(shipper, run, n):
                out[shipper] = time.time() - since
                pending.discard(shipper)
        time.sleep(0.1)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=10)
    args = parser.parse_args()

    run = uuid.uuid4().hex[:8]
    name = f"latency-{run}"
    pod = lab.pod_manifest(name, run)
    pod["spec"]["containers"][0]["command"] = ["sh", "-c", POD_SCRIPT]
    lab.kubectl("apply", "-f", "-", input_text=json.dumps(pod))
    started = time.time()
    lab.kubectl("-n", lab.NAMESPACE, "wait", "--for=condition=Ready", f"pod/{name}", "--timeout=120s")

    discovery = wait_seen(run, 0, started, 90)
    print("discovery delay (pod created -> first line in Loki):")
    for shipper, refresh in INSTANCES.items():
        print(f"  refresh_interval {refresh:>2}s  {shipper:20} {discovery.get(shipper, float('nan')):6.1f}s")

    latencies = {s: [] for s in INSTANCES}
    for n in range(1, args.samples + 1):
        time.sleep(random.uniform(2, 8))  # not aligned with any refresh cycle
        lab.on_worker(f"touch /var/lab-truth/trigger-{run}", check=True)
        for shipper, secs in wait_seen(run, n, time.time(), 30).items():
            latencies[shipper].append(secs)

    print(f"read latency on an already-tailed file ({args.samples} lines, trigger -> line in Loki):")
    for shipper, refresh in INSTANCES.items():
        vals = sorted(latencies[shipper])
        if vals:
            print(f"  refresh_interval {refresh:>2}s  {shipper:20} min {vals[0]:.2f}s  "
                  f"median {vals[len(vals) // 2]:.2f}s  max {vals[-1]:.2f}s  ({len(vals)}/{args.samples} seen)")
        else:
            print(f"  refresh_interval {refresh:>2}s  {shipper:20} no lines seen")
    lab.kubectl("-n", lab.NAMESPACE, "delete", "pod", name, "--wait=false")


if __name__ == "__main__":
    main()
