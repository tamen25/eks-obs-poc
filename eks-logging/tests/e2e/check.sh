#!/usr/bin/env bash
# Checks against the stack deployed by `run.sh apply` on kind. Each check prints PASS or FAIL;
# the script exits non-zero if any failed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK="$HERE/.work"
CTX=kind-eks-logging-e2e
K="kubectl --context $CTX"
NS=e2e-workloads
RUN=$(date +%s)
LINES=300
TMP=$(mktemp -d)
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
export AWS_CA_BUNDLE="$HERE/.certs/moto.crt"
MOTO_URL=https://127.0.0.1:25000
export PYTHONIOENCODING=utf-8
# ONLY="coverage eviction" runs just those sections; components and the gateway always run.
ONLY=${ONLY:-}
want() { [ -z "$ONLY" ] || [[ " $ONLY " == *" $1 "* ]]; }

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: got '$2', want '$3'"; fi; }

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
forward() { # namespace target local:remote
  $K -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 &
  PIDS+=($!)
  sleep 3
}

TENANT=$(terraform -chdir="$WORK" output -json loki | python -c 'import json,sys; print(json.load(sys.stdin)["tenant"])')
PASSWORD=$(terraform -chdir="$WORK" output -raw loki_tenant_password)
terraform -chdir="$WORK" output -raw loki_ca_cert_pem >"$TMP/ca.pem"
# Empty with filesystem storage.
CHUNKS_BUCKET=$(terraform -chdir="$WORK" output -json loki | python -c 'import json,sys; b = json.load(sys.stdin)["buckets"]; print(b["chunks"] if b else "")' | tr -d '\r')

echo "== components"
for ns in loki logging grafana; do
  if $K -n "$ns" wait --for=condition=Ready pod --all --timeout=300s >/dev/null 2>&1; then
    pass "all pods Ready in $ns ($($K -n "$ns" get pods --no-headers | wc -l | tr -d ' ') pods)"
  else
    fail "pods not Ready in $ns"; $K -n "$ns" get pods
  fi
done
check "NetworkPolicies created" "$($K get networkpolicy -A --no-headers | wc -l | tr -d ' ')" \
  "$($K get networkpolicy -A --no-headers | wc -l | tr -d ' ' | grep -v '^0$' || echo 0)"

echo "== gateway: TLS with the stack's CA, Basic Auth"
forward loki svc/loki-gateway 28080:8080
GW="https://loki-gateway.loki.svc:28080"
# --ssl-no-revoke: Windows curl (schannel) cannot check revocation for a private CA; other builds ignore it.
CURL=(curl -s --ssl-no-revoke --max-time 10 --cacert "$TMP/ca.pem" --resolve "loki-gateway.loki.svc:28080:127.0.0.1")
check "no credentials rejected" "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$GW/loki/api/v1/labels")" 401
check "wrong password rejected" "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -u "$TENANT:wrong" "$GW/loki/api/v1/labels")" 401
check "tenant credentials accepted, certificate verified" \
  "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -u "$TENANT:$PASSWORD" "$GW/loki/api/v1/labels")" 200

count_lines() { # LogQL selector, filter text[, regex] -> number of distinct regex matches
  "${CURL[@]}" -u "$TENANT:$PASSWORD" -G "$GW/loki/api/v1/query_range" \
    --data-urlencode "query=$1 |= \"$2\"" --data-urlencode "limit=5000" \
    --data-urlencode "start=$(( ($(date +%s) - 1800) * 1000000000 ))" |
    PAT="${3:-line [0-9]+}" python -c '
import json, os, re, sys
seen = set()
for s in json.load(sys.stdin).get("data", {}).get("result", []):
    for _, line in s["values"]:
        m = re.search(os.environ["PAT"], line)
        if m: seen.add(m.group(0))
print(len(seen))'
}
metric() { # LogQL metric query -> integer value of its first series, 0 when empty
  "${CURL[@]}" -u "$TENANT:$PASSWORD" -G "$GW/loki/api/v1/query" --data-urlencode "query=$1" |
    python -c '
import json, sys
r = json.load(sys.stdin).get("data", {}).get("result", [])
print(int(float(r[0]["value"][1])) if r else 0)'
}
query_text() { # LogQL -> all lines joined
  "${CURL[@]}" -u "$TENANT:$PASSWORD" -G "$GW/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "limit=1000" \
    --data-urlencode "start=$(( ($(date +%s) - 1800) * 1000000000 ))" |
    python -c '
import json, sys
for s in json.load(sys.stdin).get("data", {}).get("result", []):
    for _, line in s["values"]: print(line)'
}

$K create namespace "$NS" >/dev/null 2>&1 || true

if want eviction; then
echo "== eviction scenarios (run $RUN, $LINES lines each)"
pod() { # name, extra container yaml, command
  cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 30
  containers:
    - name: ${1%-$RUN}
      image: busybox:1.37
      command: ["sh", "-c", "for i in \$(seq 1 $LINES); do echo \"e2e $1 line \$i\"; done; $3"]
      terminationMessagePolicy: FallbackToLogsOnError
$2
EOF
}

# 1. Eviction API with no grace period, one second after the pod is Ready (drain, Karpenter).
pod "api-evict-$RUN" "" "sleep 3600"
$K -n "$NS" wait --for=condition=Ready "pod/api-evict-$RUN" --timeout=120s >/dev/null
sleep 1
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"api-evict-%s","namespace":"%s"},"deleteOptions":{"gracePeriodSeconds":0}}' "$RUN" "$NS" >"$TMP/eviction.json"
# MSYS_NO_PATHCONV: Git Bash would otherwise rewrite the API path into a Windows path.
MSYS_NO_PATHCONV=1 $K create --raw "/api/v1/namespaces/$NS/pods/api-evict-$RUN/eviction"   -f "$(cygpath -w "$TMP/eviction.json" 2>/dev/null || echo "$TMP/eviction.json")" >/dev/null
if $K -n "$NS" wait --for=delete "pod/api-evict-$RUN" --timeout=30s >/dev/null 2>&1; then
  pass "Eviction API removed api-evict"
else
  fail "Eviction API did not remove api-evict"
fi

# 2. Kubelet eviction: the pod outgrows its ephemeral-storage limit.
pod "kubelet-evict-$RUN" "      resources:
        limits:
          ephemeral-storage: 20Mi
      volumeMounts:
        - name: scratch
          mountPath: /scratch
  volumes:
    - name: scratch
      emptyDir: {}" "sleep 2; dd if=/dev/zero of=/scratch/fill bs=1M count=80; sleep 3600"

# 3. Force delete as soon as the pod runs.
pod "force-delete-$RUN" "" "sleep 3600"
$K -n "$NS" wait --for=condition=Ready "pod/force-delete-$RUN" --timeout=120s >/dev/null
$K -n "$NS" delete pod "force-delete-$RUN" --grace-period=0 --force >/dev/null 2>&1

# 4. A pod that lives about a second and is deleted as soon as it completes.
pod "short-lived-$RUN" "" "exit 0"
for _ in $(seq 60); do
  phase=$($K -n "$NS" get pod "short-lived-$RUN" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = "Succeeded" ] && break; sleep 0.5
done
$K -n "$NS" delete pod "short-lived-$RUN" --wait=false >/dev/null

for _ in $(seq 60); do
  reason=$($K -n "$NS" get pod "kubelet-evict-$RUN" -o jsonpath='{.status.reason}' 2>/dev/null)
  [ "$reason" = "Evicted" ] && break; sleep 2
done
check "kubelet evicted the ephemeral-storage pod" "$reason" Evicted
$K -n "$NS" delete pod "kubelet-evict-$RUN" --wait=false >/dev/null

sleep 25 # file discovery, flush, Loki ingestion
for name in api-evict kubelet-evict force-delete short-lived; do
  got=$(count_lines "{cluster=\"e2e-cluster\", namespace=\"$NS\", container=\"$name\"}" "e2e $name-$RUN line")
  check "$name: lines in Loki" "$got" "$LINES"
done

echo "== events and pod-lifecycle records"
check "Evicted event (kubelet eviction, with reason)" \
  "$(query_text "{job=\"kubernetes-events\", namespace=\"$NS\", reason=\"Evicted\"} | object=\"kubelet-evict-$RUN\"" | grep -cE "low on resource|exceeds the total limit" | awk '{print ($1>0)?"yes":"no"}')" yes
lifecycle=$(query_text "{namespace=\"logging\", container=\"watch\"} |= \"$RUN\"")
check "pod-lifecycle: Eviction API disruption recorded" \
  "$(echo "$lifecycle" | grep "api-evict-$RUN" | grep -c EvictionByEvictionAPI | awk '{print ($1>0)?"yes":"no"}')" yes
check "pod-lifecycle: kubelet eviction recorded with last lines" \
  "$(echo "$lifecycle" | grep "kubelet-evict-$RUN" | grep -c '"Evicted"' | awk '{print ($1>0)?"yes":"no"}')" yes
fi

if want coverage; then
echo "== cluster-wide collection (run $RUN)"
# This stack is the cluster's only log pipeline, so everything a workload can write has to
# arrive whole and labelled, from every namespace and node, without drops.

# Init container, two containers, stdout and stderr, a JSON line with non-ASCII text, a 100 KB
# line (the runtime splits it into 16 KB partials that the agent must join again) and a 400 KB
# line (over Loki's max_line_size: truncated, and the lines after it must still arrive).
JSON_LINE='{"level":"info","msg":"e2e json-'$RUN'","user":"zoë ✓","n":42}'
cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: shapes-$RUN
  namespace: $NS
spec:
  restartPolicy: Never
  initContainers:
    - name: init
      image: busybox:1.37
      command: ["sh", "-c", "for i in \$(seq 1 50); do echo \"e2e shapes-$RUN init line \$i\"; done"]
  containers:
    - name: app
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          for i in \$(seq 1 50); do echo "e2e shapes-$RUN stdout line \$i"; echo "e2e shapes-$RUN stderr line \$i" >&2; done
          echo '$JSON_LINE'
          printf 'e2e long100k-$RUN '; head -c 100000 /dev/zero | tr '\0' x; echo
          printf 'e2e long400k-$RUN '; head -c 400000 /dev/zero | tr '\0' y; echo
          for i in \$(seq 1 50); do echo "e2e shapes-$RUN after-long line \$i"; done
          sleep 3600
    - name: sidecar
      image: busybox:1.37
      command: ["sh", "-c", "for i in \$(seq 1 50); do echo \"e2e shapes-$RUN sidecar line \$i\"; done; sleep 3600"]
EOF

# About 40 MB on disk in 30 one-second batches. The kubelet rotates container logs at 10 Mi
# (the kind and EKS default), so the agent has to follow the file through several rotations.
BATCHES=30 PER_BATCH=10000
cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: burst-$RUN
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: burst
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          for b in \$(seq 1 $BATCHES); do
            awk -v b=\$b 'BEGIN { for (i = 1; i <= $PER_BATCH; i++) printf "e2e burst-$RUN b%d l%d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", b, i }'
            sleep 1
          done
          echo "e2e burst-$RUN done"
          sleep 3600
EOF

$K -n "$NS" wait --for=condition=Ready "pod/burst-$RUN" --timeout=120s >/dev/null
burst_node=$($K -n "$NS" get pod "burst-$RUN" -o jsonpath='{.spec.nodeName}')

# Containers that crash three times each, started on the burst's node while its log is being
# rotated: each attempt writes a new log file, and the first two attempts are a second apart.
# With the inotify watcher about 1 in 40 such files was never read.
CRASHERS=8
sleep 12 # the burst's first rotation
for c in $(seq "$CRASHERS"); do
  cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: crashloop-$RUN-$c
  namespace: $NS
spec:
  nodeName: $burst_node
  restartPolicy: Always
  containers:
    - name: crashloop
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          n=\$(( \$(cat /state/boots 2>/dev/null || echo 0) + 1 )); echo \$n >/state/boots
          for i in \$(seq 1 100); do echo "e2e crashloop-$RUN-$c boot \$n line \$i"; done
          exit 1
      volumeMounts:
        - name: state
          mountPath: /state
  volumes:
    - name: state
      emptyDir: {}
EOF
done

for _ in $(seq 120); do
  $K -n "$NS" logs "burst-$RUN" --tail=1 2>/dev/null | grep -q "burst-$RUN done" && break; sleep 2
done
rotated=$(MSYS_NO_PATHCONV=1 docker exec "$burst_node" sh -c "ls /var/log/pods/${NS}_burst-${RUN}_*/burst/" | grep -vcx '0.log')
check "kubelet rotated the burst container's log at least twice" "$( [ "$rotated" -ge 2 ] && echo yes || echo "no ($rotated)")" yes

for _ in $(seq 60); do
  restarted=$($K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].restartCount}{"\n"}{end}' |
    awk -v p="crashloop-$RUN-" 'index($1, p) == 1 && $2 >= 2' | wc -l | tr -d ' ')
  [ "$restarted" -ge "$CRASHERS" ] && break; sleep 2
done
sleep 5 # the third attempt writes its lines
for c in $(seq "$CRASHERS"); do $K -n "$NS" delete pod "crashloop-$RUN-$c" --wait=false >/dev/null; done

total=$((BATCHES * PER_BATCH))
for _ in $(seq 40); do # 30 MB through the agent and Loki takes a while on a laptop
  got=$(metric "sum(count_over_time({cluster=\"e2e-cluster\", namespace=\"$NS\", container=\"burst\"} |= \"e2e burst-$RUN b\" [1h]))")
  [ "$got" -ge "$total" ] && break; sleep 5
done
check "burst: every line through the rotations, no duplicates" "$got" "$total"

sel="{cluster=\"e2e-cluster\", namespace=\"$NS\""
check "init container lines" "$(count_lines "$sel, container=\"init\"}" "e2e shapes-$RUN init line")" 50
check "sidecar container lines" "$(count_lines "$sel, container=\"sidecar\"}" "e2e shapes-$RUN sidecar line")" 50
check "stdout lines, tagged stream=stdout" "$(count_lines "$sel, container=\"app\"} | stream=\"stdout\"" "e2e shapes-$RUN stdout line")" 50
check "stderr lines, tagged stream=stderr" "$(count_lines "$sel, container=\"app\"} | stream=\"stderr\"" "e2e shapes-$RUN stderr line")" 50
check "crash-looping containers during rotation: 100 lines from each of 3 attempts x $CRASHERS" \
  "$(count_lines "$sel, container=\"crashloop\"} |~ \"boot [123] line\"" "e2e crashloop-$RUN-" 'crashloop-[0-9]+-[0-9]+ boot [0-9]+ line [0-9]+')" $((CRASHERS * 300))

got_json=$(query_text "$sel, container=\"app\"} |= \"e2e json-$RUN\"" | head -1)
check "JSON line with non-ASCII text arrives byte for byte" \
  "$( [ "$got_json" = "$JSON_LINE" ] && echo same || echo "different: $got_json")" same
line_len() { query_text "$sel, container=\"app\"} |= \"$1\"" | head -1 | tr -d '\r\n' | wc -c | tr -d ' '; }
check "100 KB line joined from its 16 KB partials" "$(line_len "e2e long100k-$RUN")" $((100000 + ${#RUN} + 14))
long400=$(line_len "e2e long400k-$RUN")
check "400 KB line kept, truncated to Loki's max_line_size" \
  "$( [ "$long400" -gt 200000 ] && [ "$long400" -lt 400000 ] && echo yes || echo "no ($long400 bytes)")" yes
check "lines after the oversized line still arrive" "$(count_lines "$sel, container=\"app\"}" "e2e shapes-$RUN after-long line")" 50

# Every container on every node that has written anything has a stream in Loki: the system
# namespaces, the stack's own pods, all of it. Nothing is excluded by default.
nodes=$(docker ps --filter "label=io.x-k8s.kind.cluster=eks-logging-e2e" --format '{{.Names}}')
on_disk=$(for n in $nodes; do MSYS_NO_PATHCONV=1 docker exec "$n" find -L /var/log/containers -name '*.log' -size +0; done |
  sed -E 's#^/var/log/containers/[^_]+_([^_]+)_(.+)-[0-9a-f]{64}\.log$#\1/\2#' | sort -u)
in_loki=$("${CURL[@]}" -u "$TENANT:$PASSWORD" -G "$GW/loki/api/v1/series" \
  --data-urlencode 'match[]={cluster="e2e-cluster", container=~".+"}' \
  --data-urlencode "start=$(( ($(date +%s) - 86400) * 1000000000 ))" |
  python -c '
import json, sys
for s in json.load(sys.stdin)["data"]: print(s["namespace"] + "/" + s["container"])' | tr -d '\r' | sort -u)
missing=$(comm -23 <(echo "$on_disk") <(echo "$in_loki"))
check "containers with output on a node but no stream in Loki" "$(printf '%s' "$missing" | grep -c .)" 0
[ -n "$missing" ] && echo "      missing: $(echo $missing)"
echo "      on disk: $(echo "$on_disk" | wc -l | tr -d ' ') containers in $(echo "$on_disk" | cut -d/ -f1 | sort -u | wc -l | tr -d ' ') namespaces ($(echo "$on_disk" | cut -d/ -f1 | sort -u | tr '\n' ' '))"

# Node services write to journald, not /var/log/containers.
for n in $nodes; do
  for unit in kubelet.service containerd.service; do
    got=$(metric "sum(count_over_time({cluster=\"e2e-cluster\", job=\"node\", unit=\"$unit\"} | node=\"$n\" [1h]))")
    check "$unit journal from $n" "$( [ "$got" -gt 0 ] && echo yes || echo no)" yes
  done
done

# Anything an agent gave up on would be missing from Loki without a trace in the checks above.
dropped=0 port=28400
for p in $($K -n logging get pods -l app.kubernetes.io/instance=fluent-bit -o name); do
  port=$((port + 1))
  forward logging "$p" "$port:2020"
  n=$(curl -s --max-time 10 "http://127.0.0.1:$port/api/v2/metrics/prometheus" |
    awk '/^fluentbit_output_(dropped_records|retries_failed)_total/ { s += $2; c++ } END { print (c ? s : "unreadable") }')
  [ "$n" = unreadable ] && { dropped="metrics unreadable on $p"; break; }
  dropped=$((dropped + n))
done
check "records dropped or abandoned by the agents" "$dropped" 0

$K -n "$NS" delete pod "shapes-$RUN" "burst-$RUN" --wait=false >/dev/null
fi

if want netpol; then
echo "== NetworkPolicies enforced"
probe() { # namespace, labels -> HTTP code from the gateway (000 = blocked)
  $K -n "$1" run "probe-$RANDOM" --rm -i --restart=Never --quiet --labels="$2" \
    --image=curlimages/curl:8.16.0 --command -- \
    curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://loki-gateway.loki.svc:8080/loki/api/v1/labels 2>/dev/null |
    tr -dc '0-9' | cut -c1-3
}
check "pod in another namespace cannot reach the gateway" "$(probe "$NS" app=probe)" 000
check "Fluent Bit-labelled pod in logging reaches the gateway (401 = reached, no credentials)" \
  "$(probe logging app.kubernetes.io/name=fluent-bit)" 401
check "unlabelled pod in logging cannot reach the gateway" "$(probe logging app=probe)" 000
fi

if want storage && [ -z "$CHUNKS_BUCKET" ]; then
echo "== filesystem storage: no AWS resources, logs on Loki's volume"
check "AWS resources in the Terraform state" \
  "$(terraform -chdir="$WORK" state list | grep -v 'data\.aws_' | grep -c -E '(^|\.)aws_')" 0
check "buckets in the AWS account" \
  "$(aws --endpoint-url "$MOTO_URL" s3api list-buckets --query 'length(Buckets)' --output text | tr -d '\r')" 0
# A fixed window, so lines arriving during the check cannot change the count. Lines still in
# memory must come back from the write-ahead log on the volume.
window_end=$(( $(date +%s) - 30 ))
lines_in_window() {
  "${CURL[@]}" -u "$TENANT:$PASSWORD" -G "$GW/loki/api/v1/query" --data-urlencode "time=$window_end" \
    --data-urlencode 'query=sum(count_over_time({namespace=~".+"} [10m]))' | python -c '
import json, sys
r = json.load(sys.stdin).get("data", {}).get("result", [])
print(int(float(r[0]["value"][1])) if r else 0)' | tr -d '\r'
}
before=$(lines_in_window)
$K -n loki delete pod loki-0 >/dev/null
sleep 5
if $K -n loki wait --for=condition=Ready pod/loki-0 --timeout=300s >/dev/null 2>&1; then
  sleep 10
  check "lines before Loki's restart are all there after it" "$(lines_in_window)" "$before"
  check "that count covers real lines" "$([ "$before" -gt 0 ] && echo yes || echo no)" yes
else
  fail "loki-0 not Ready after its restart"
fi
fi

if want storage && [ -n "$CHUNKS_BUCKET" ]; then
echo "== S3 layout matches the hot/warm tier rule"
# The tier rule matches "<tenant>/" (modules/loki/storage, unit-tested; moto cannot hold the
# rule, see storage_override.tf). Here: does Loki really put chunks, and only chunks, there?
forward loki pod/loki-0 28100:3100
curl -s -X POST --max-time 30 http://127.0.0.1:28100/flush >/dev/null
sleep 15
keys=$(aws --endpoint-url "$MOTO_URL" s3api list-objects-v2 --bucket "$CHUNKS_BUCKET" --query 'Contents[].Key' --output text | tr '\t' '\n')
check "Loki wrote chunks under the tier rule's prefix ($TENANT/)" "$(echo "$keys" | grep -c "^$TENANT/" | awk '{print ($1>0)?"yes":"no"}')" yes
check "nothing else under the tiered prefix but chunks" "$(echo "$keys" | grep "^$TENANT/" | grep -vc '^[^/]*/[0-9a-f]*/[0-9a-f]*:[0-9a-f]*:[0-9a-f]*$')" 0
echo "      object prefixes in the bucket: $(echo "$keys" | cut -d/ -f1 | sort | uniq -c | tr '\n' ' ')"
fi

if want grafana; then
echo "== Grafana datasource (password and CA from mounted files)"
forward grafana svc/grafana 28300:3000
admin=$($K -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
health=$(curl -s --max-time 30 -u "admin:$admin" http://127.0.0.1:28300/api/datasources/uid/loki/health |
  python -c 'import json,sys; print(json.load(sys.stdin).get("status"))')
check "Grafana -> Loki datasource health" "$health" OK
fi

echo
if [ "$failures" -eq 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; exit 1; fi
