#!/usr/bin/env bash
# Runs each test scenario once in the scenarios namespace, then compares the lines each one
# wrote with the lines in Loki. The "6 · Test scenarios" dashboard shows the same numbers.
#
# Every counted line reads: scenario=<name> run=<run id> expected=<lines the scenario writes> line=<n>
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
K="kubectl --context kind-logging-poc"
NS=scenarios
RUN=$(date +%s)
LINES=300
CRASHERS=4
SCENARIOS=14 # burst, init, stdout, stderr, long-100k, long-400k, after-long, sidecar,
             # evict-api, evict-kubelet, force-delete, short-lived, oom-kill, crashloop
TMP=$(mktemp -d)
export PYTHONIOENCODING=utf-8

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

say() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
lines() { # scenario, expected, count -> shell loop writing the counted lines
  echo "for i in \$(seq 1 $3); do echo \"scenario=$1 run=$RUN expected=$2 line=\$i\"; done"
}
pod() { # name, shell command, extra container yaml, extra pod spec yaml, restart policy
  cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1-$RUN
  namespace: $NS
  labels: { scenario: "$1", run: "$RUN" }
spec:
  restartPolicy: ${5:-Never}
  terminationGracePeriodSeconds: 30
  containers:
    - name: ${1}
      image: busybox:1.37
      # A block scalar takes the command literally: no YAML escaping of its quotes.
      command:
        - sh
        - -c
        - |
          $2
      terminationMessagePolicy: FallbackToLogsOnError
${3:-}
${4:-}
EOF
}
wait_ready() { $K -n "$NS" wait --for=condition=Ready "pod/$1-$RUN" --timeout=120s >/dev/null; }

say "run $RUN: starting scenarios in namespace $NS"

# burst: 300,000 lines of about 100 bytes, enough for the kubelet to rotate the 10 MiB log.
pod burst "for b in \$(seq 0 29); do awk -v r=$RUN -v b=\$b 'BEGIN { for (i = 1; i <= 10000; i++) printf \"scenario=burst run=%s expected=300000 line=%d pad=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n\", r, b * 10000 + i }'; sleep 1; done; echo burst finished; sleep 3600"

# init, sidecar, stdout, stderr and oversized lines, all in one pod.
x() { echo "head -c $1 /dev/zero | tr '\\0' x"; } # a line of $1 x characters
cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: shapes-$RUN
  namespace: $NS
  labels: { scenario: "shapes", run: "$RUN" }
spec:
  restartPolicy: Never
  initContainers:
    - name: init
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          $(lines init 50 50)
  containers:
    - name: app
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          $(lines stdout 50 50)
          $(lines stderr 50 50) >&2
          printf 'scenario=long-100k run=$RUN expected=1 line=1 payload='; $(x 100000); echo
          printf 'scenario=long-400k run=$RUN expected=1 line=1 payload='; $(x 400000); echo
          $(lines after-long 50 50)
          sleep 3600
    - name: sidecar
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          $(lines sidecar 50 50); sleep 3600
EOF

# evict-api: evicted through the Eviction API with no grace period, as a drain would.
pod evict-api "$(lines evict-api $LINES $LINES); sleep 3600"
# evict-kubelet: outgrows its ephemeral-storage limit, so the kubelet evicts it.
pod evict-kubelet "$(lines evict-kubelet $LINES $LINES); sleep 2; dd if=/dev/zero of=/scratch/fill bs=1M count=80; sleep 3600" \
  "      resources: { limits: { ephemeral-storage: 20Mi } }
      volumeMounts: [{ name: scratch, mountPath: /scratch }]" \
  "  volumes: [{ name: scratch, emptyDir: {} }]"
# force-delete: deleted with no grace period as soon as it runs.
pod force-delete "$(lines force-delete $LINES $LINES); sleep 3600"
# short-lived: exits at once and is deleted as soon as it completes.
pod short-lived "$(lines short-lived $LINES $LINES); exit 0"
# oom-kill: writes its lines, then tail buffers /dev/zero (no newline ever) past the limit.
pod oom-kill "$(lines oom-kill 100 100); sleep 2; tail /dev/zero" \
  "      resources: { limits: { memory: 32Mi } }"

# crashloop: exits straight away; the first three attempts write counted lines. A counter on
# an emptyDir (kept across restarts) tells the attempts apart.
for c in $(seq "$CRASHERS"); do
  pod "crashloop-$c" "n=\$(( \$(cat /state/n 2>/dev/null || echo 0) + 1 )); echo \$n > /state/n; if [ \$n -le 3 ]; then for i in \$(seq 1 100); do echo \"scenario=crashloop run=$RUN expected=$((CRASHERS * 300)) attempt=\$n line=$c-\$i\"; done; else echo \"crashloop attempt \$n, not counted\"; fi; exit 1" \
    "      volumeMounts: [{ name: state, mountPath: /state }]" \
    "  volumes: [{ name: state, emptyDir: {} }]" Always
done

# Two failures that only the node logs and events show (no counted lines): an image that does
# not exist, and a readiness probe that always fails. Deleted with the rest at the end.
cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: bad-image-$RUN
  namespace: $NS
  labels: { scenario: "bad-image", run: "$RUN" }
spec:
  containers:
    - name: app
      image: registry.invalid/does-not-exist:1.0
---
apiVersion: v1
kind: Pod
metadata:
  name: failing-probe-$RUN
  namespace: $NS
  labels: { scenario: "failing-probe", run: "$RUN" }
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sleep", "3600"]
      readinessProbe:
        exec: { command: ["false"] }
        periodSeconds: 5
EOF

wait_ready evict-api && sleep 1
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"evict-api-%s","namespace":"%s"},"deleteOptions":{"gracePeriodSeconds":0}}' "$RUN" "$NS" >"$TMP/eviction.json"
# MSYS_NO_PATHCONV: Git Bash would otherwise rewrite the API path into a Windows path.
MSYS_NO_PATHCONV=1 $K create --raw "/api/v1/namespaces/$NS/pods/evict-api-$RUN/eviction" \
  -f "$(cygpath -w "$TMP/eviction.json" 2>/dev/null || echo "$TMP/eviction.json")" >/dev/null && say "evict-api: evicted through the API"

wait_ready force-delete && $K -n "$NS" delete pod "force-delete-$RUN" --grace-period=0 --force >/dev/null 2>&1 && say "force-delete: force-deleted"

for _ in $(seq 60); do
  [ "$($K -n "$NS" get pod "short-lived-$RUN" -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ] && break; sleep 0.5
done
$K -n "$NS" delete pod "short-lived-$RUN" --wait=false >/dev/null && say "short-lived: completed and deleted"

for _ in $(seq 60); do
  reason=$($K -n "$NS" get pod "evict-kubelet-$RUN" -o jsonpath='{.status.reason}' 2>/dev/null)
  [ "$reason" = Evicted ] && break; sleep 2
done
say "evict-kubelet: pod status reason '$reason'"

for _ in $(seq 60); do
  oom=$($K -n "$NS" get pod "oom-kill-$RUN" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)
  [ -n "$oom" ] && break; sleep 2
done
say "oom-kill: container ended with '$oom'"

for _ in $(seq 60); do
  restarted=$($K -n "$NS" get pods -l "run=$RUN" -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].restartCount}{"\n"}{end}' |
    awk '/^crashloop-/ && $2 >= 2' | wc -l | tr -d ' ')
  [ "$restarted" -ge "$CRASHERS" ] && break; sleep 2
done
sleep 5 # the third attempt writes its lines
for c in $(seq "$CRASHERS"); do $K -n "$NS" delete pod "crashloop-$c-$RUN" --wait=false >/dev/null; done
say "crashloop: $CRASHERS pods ran 3 attempts, deleted"

for _ in $(seq 120); do
  $K -n "$NS" logs "burst-$RUN" --tail=1 2>/dev/null | grep -q "burst finished" && break; sleep 2
done
rotated=$(MSYS_NO_PATHCONV=1 docker exec "$($K -n "$NS" get pod "burst-$RUN" -o jsonpath='{.spec.nodeName}')" \
  sh -c "ls /var/log/pods/${NS}_burst-${RUN}_*/burst/" | grep -vcx '0.log')
say "burst: finished writing, kubelet rotated its log $rotated time(s)"

# Compare lines written with lines in Loki, through the gateway with the tenant's password.
TENANT=$(terraform -chdir="$HERE" output -raw loki_tenant)
PASSWORD=$(terraform -chdir="$HERE" output -raw loki_tenant_password)
$K -n observability port-forward svc/loki-gateway 23111:80 >/dev/null 2>&1 &
PIDS+=($!)
sleep 3
query() {
  curl -s --max-time 30 -u "$TENANT:$PASSWORD" -G http://127.0.0.1:23111/loki/api/v1/query --data-urlencode "query=$1" |
    python -c '
import json, sys
for r in json.load(sys.stdin).get("data", {}).get("result", []):
    print(r["metric"]["scenario"], int(float(r["value"][1])))' | tr -d '\r' | sort
}
# keep: only these fields become labels (line= and payload= would make every line a series).
sel="{namespace=\"$NS\"} | logfmt | keep scenario, run, expected | scenario!=\"\" | run=\"$RUN\""
say "waiting for Loki to receive every line (up to 5 minutes)"
for _ in $(seq 60); do
  query "sum by (scenario) (count_over_time($sel [1h]))" >"$TMP/got"
  query "max by (scenario) (max_over_time($sel | unwrap expected | __error__=\"\" [1h]))" >"$TMP/want"
  [ -s "$TMP/want" ] && join "$TMP/want" "$TMP/got" | awk '$2 != $3 { d = 1 } END { exit d }' &&
    [ "$(wc -l <"$TMP/want")" -eq "$SCENARIOS" ] && break
  sleep 5
done

echo
printf '%-14s %10s %10s %10s\n' scenario written received delivered
failures=0
while read -r name want; do
  got=$(awk -v n="$name" '$1 == n { print $2 }' "$TMP/got")
  got=${got:-0}
  pct=$(awk -v g="$got" -v w="$want" 'BEGIN { printf "%.1f%%", 100 * g / w }')
  printf '%-14s %10s %10s %10s\n' "$name" "$want" "$got" "$pct"
  [ "$got" = "$want" ] || failures=$((failures + 1))
done <"$TMP/want"
echo
$K -n "$NS" delete pod -l "run=$RUN" --wait=false >/dev/null
if [ "$(wc -l <"$TMP/want")" -ne "$SCENARIOS" ]; then
  echo "expected $SCENARIOS scenarios in Loki, found $(wc -l <"$TMP/want")"; exit 1
fi
if [ "$failures" -eq 0 ]; then echo "Every scenario delivered every line (run $RUN)."; else echo "$failures scenario(s) short (run $RUN)."; exit 1; fi
