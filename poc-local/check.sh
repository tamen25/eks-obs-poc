#!/usr/bin/env bash
# Checks against the POC deployed by `run.sh apply`. Each check prints PASS or FAIL; the
# script exits non-zero if any failed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLUSTER=logging-poc
K="kubectl --context kind-$CLUSTER"
TMP=$(mktemp -d)
export PYTHONIOENCODING=utf-8

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: got '$2', want '$3'"; fi; }
yes_if() { if eval "$1"; then echo yes; else echo no; fi; }

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
forward() { # namespace target local:remote
  $K -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 &
  PIDS+=($!)
  sleep 3
}

TENANT=$(terraform -chdir="$HERE" output -raw loki_tenant)
TENANT_PASSWORD=$(terraform -chdir="$HERE" output -raw loki_tenant_password)
ADMIN_PASSWORD=$(terraform -chdir="$HERE" output -raw grafana_admin_password)
SINCE=$(( ($(date +%s) - 3600) * 1000000000 ))

echo "== components"
for ns in observability logging demo; do
  if $K -n "$ns" wait --for=condition=Ready pod --all --timeout=300s >/dev/null 2>&1; then
    pass "all pods Ready in $ns ($($K -n "$ns" get pods --no-headers | wc -l | tr -d ' ') pods)"
  else
    fail "pods not Ready in $ns"; $K -n "$ns" get pods
  fi
done

echo "== Loki gateway: Basic Auth maps the user to its tenant"
forward observability svc/loki-gateway 23101:80
GW=http://127.0.0.1:23101
CURL=(curl -s --max-time 15)
check "no credentials rejected" "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$GW/loki/api/v1/labels")" 401
check "wrong password rejected" "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -u "$TENANT:wrong" "$GW/loki/api/v1/labels")" 401
check "tenant credentials accepted" "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -u "$TENANT:$TENANT_PASSWORD" "$GW/loki/api/v1/labels")" 200

metric() { # LogQL metric query -> integer value of its first series, 0 when empty
  "${CURL[@]}" -u "$TENANT:$TENANT_PASSWORD" -G "$GW/loki/api/v1/query" --data-urlencode "query=$1" |
    python -c '
import json, sys
r = json.load(sys.stdin).get("data", {}).get("result", [])
print(int(float(r[0]["value"][1])) if r else 0)'
}

echo "== logs"
# Every container on every node that has written anything has a stream in Loki.
nodes=$(docker ps --filter "label=io.x-k8s.kind.cluster=$CLUSTER" --format '{{.Names}}')
on_disk=$(for n in $nodes; do MSYS_NO_PATHCONV=1 docker exec "$n" find -L /var/log/containers -name '*.log' -size +0; done |
  sed -E 's#^/var/log/containers/[^_]+_([^_]+)_(.+)-[0-9a-f]{64}\.log$#\1/\2#' | tr -d '\r' | sort -u)
in_loki=$("${CURL[@]}" -u "$TENANT:$TENANT_PASSWORD" -G "$GW/loki/api/v1/series" \
  --data-urlencode 'match[]={cluster="poc", container=~".+"}' --data-urlencode "start=$SINCE" |
  python -c '
import json, sys
for s in json.load(sys.stdin)["data"]: print(s["namespace"] + "/" + s["container"])' | tr -d '\r' | sort -u)
missing=$(comm -23 <(echo "$on_disk") <(echo "$in_loki"))
check "containers with output on a node but no stream in Loki" "$(printf '%s' "$missing" | grep -c .)" 0
[ -n "$missing" ] && echo "      missing: $(echo $missing)"
echo "      on disk: $(echo "$on_disk" | wc -l | tr -d ' ') containers in $(echo "$on_disk" | cut -d/ -f1 | sort -u | wc -l | tr -d ' ') namespaces ($(echo "$on_disk" | cut -d/ -f1 | sort -u | tr '\n' ' '))"

for n in $nodes; do
  for unit in kubelet.service containerd.service; do
    got=$(metric "sum(count_over_time({cluster=\"poc\", job=\"node\", unit=\"$unit\"} | node=\"$n\" [1h]))")
    check "$unit journal from $n" "$(yes_if "[ $got -gt 0 ]")" yes
  done
done
check "Kubernetes events collected" "$(yes_if "[ $(metric 'sum(count_over_time({job="kubernetes-events"} [1h]))') -gt 0 ]")" yes

# Older events would hide a collector that has stopped, so this makes new ones: a pod, evicted,
# with its events counted per reason on both sides. It selects by the object metadata because
# the name is not in the line; a text search would only find events whose message mentions it.
api_events() { # pod -> Reason=count ..., from the API server
  $K -n scenarios get events --field-selector "involvedObject.name=$1" -o json | python -c '
import collections, json, sys
counts = collections.Counter(e["reason"] for e in json.load(sys.stdin)["items"])
print(" ".join(f"{r}={counts[r]}" for r in sorted(counts)))' | tr -d '\r'
}
loki_events() { # pod -> Reason=count ..., from Loki
  "${CURL[@]}" -u "$TENANT:$TENANT_PASSWORD" -G "$GW/loki/api/v1/query" \
    --data-urlencode "query=sum by (reason) (count_over_time({job=\"kubernetes-events\", namespace=\"scenarios\"} | object=\"$1\" [10m]))" |
    python -c '
import json, sys
series = json.load(sys.stdin).get("data", {}).get("result", [])
counts = {s["metric"]["reason"]: int(s["value"][1]) for s in series}
print(" ".join(f"{r}={counts[r]}" for r in sorted(counts)))' | tr -d '\r'
}
probe=event-check-$(date +%s)
$K -n scenarios run "$probe" --image=busybox:1.37 --restart=Never --command -- sleep 3600 >/dev/null
if $K -n scenarios wait --for=condition=Ready "pod/$probe" --timeout=120s >/dev/null; then
  printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"scenarios"}}' "$probe" |
    MSYS_NO_PATHCONV=1 $K create --raw "/api/v1/namespaces/scenarios/pods/$probe/eviction" -f - >/dev/null
  for _ in $(seq 20); do
    want=$(api_events "$probe")
    got=$(loki_events "$probe")
    case "$want" in *Killing=*) [ "$want" = "$got" ] && break ;; esac
    sleep 3
  done
  case "$want" in
    *Killing=*) check "a new evicted pod's events in Loki match the API, per reason" "$got" "$want" ;;
    *) fail "the evicted pod has no Killing event in the API: '$want'" ;;
  esac
else
  fail "event check pod $probe not Ready"
fi
$K -n scenarios delete pod "$probe" --ignore-not-found --wait=false >/dev/null

dropped=0 port=23400
for p in $($K -n logging get pods -l app.kubernetes.io/instance=fluent-bit -o name); do
  port=$((port + 1))
  forward logging "$p" "$port:2020"
  n=$(curl -s --max-time 10 "http://127.0.0.1:$port/api/v2/metrics/prometheus" |
    awk '/^fluentbit_output_(dropped_records|retries_failed)_total/ { s += $2; c++ } END { print (c ? s : "unreadable") }')
  [ "$n" = unreadable ] && { dropped="metrics unreadable on $p"; break; }
  dropped=$((dropped + n))
done
check "records dropped or abandoned by the agents" "$dropped" 0

forward observability svc/loki 23102:3100
check "non-prod namespaces get their own retention" \
  "$(yes_if "curl -s --max-time 10 http://127.0.0.1:23102/config | grep -q 'uat|preprod'")" yes

echo "== traces and the link between logs and traces (through Grafana's data sources)"
forward observability svc/grafana 23031:80
GF=(curl -s --max-time 20 -u "admin:$ADMIN_PASSWORD")
G=http://127.0.0.1:23031
check "Grafana opens without a login" \
  "$(curl -s --max-time 20 "$G/api/datasources/uid/loki" | python -c 'import json,sys; print(json.load(sys.stdin).get("uid"))')" loki
for uid in loki tempo; do
  check "Grafana -> $uid data source health" \
    "$("${GF[@]}" "$G/api/datasources/uid/$uid/health" | python -c 'import json,sys; print(json.load(sys.stdin).get("status"))')" OK
done

# Grafana expands $VAR in provisioning files; a wrong escape leaves a link that goes nowhere.
check "log lines link to their trace (TraceID field URL)" \
  "$("${GF[@]}" "$G/api/datasources/uid/loki" | python -c 'import json,sys; print(json.load(sys.stdin)["jsonData"]["derivedFields"][0]["url"])')" \
  '${__value.raw}'

demo_lines=$(metric 'sum(count_over_time({namespace="demo", container="app"} |= "order received" [1h]))')
check "demo service logs in Loki" "$(yes_if "[ $demo_lines -gt 0 ]")" yes

# A trace ID taken from a log line at least 30s old, so its spans have been flushed to Tempo.
trace_id=$("${CURL[@]}" -u "$TENANT:$TENANT_PASSWORD" -G "$GW/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="demo"} |= "payment"' --data-urlencode "limit=1" \
  --data-urlencode "start=$SINCE" --data-urlencode "end=$(( ($(date +%s) - 30) * 1000000000 ))" |
  python -c '
import json, re, sys
for s in json.load(sys.stdin).get("data", {}).get("result", []):
    for _, line in s["values"]:
        m = re.search(r"trace_id=([0-9a-f]{32})", line)
        if m: print(m.group(1)); sys.exit()')
check "a demo log line carries a trace ID" "$(yes_if "[ -n '$trace_id' ]")" yes

"${GF[@]}" -H 'Accept: application/json' "$G/api/datasources/proxy/uid/tempo/api/traces/$trace_id" >"$TMP/trace.json"
summary=$(python - "$TMP/trace.json" <<'EOF'
import json, sys
try:
    batches = json.load(open(sys.argv[1])).get("batches", [])
except ValueError:
    print("unreadable"); sys.exit()
attrs, spans = {}, set()
for b in batches:
    for a in b["resource"]["attributes"]:
        attrs[a["key"]] = a["value"].get("stringValue")
    for ss in b.get("scopeSpans", []):
        for s in ss["spans"]:
            spans.add(s["name"])
print(attrs.get("service.name"), attrs.get("k8s.namespace.name"), ",".join(sorted(spans)))
EOF
)
check "that trace is in Tempo, with its spans and the pod's namespace" "$summary" "demo-checkout demo checkout,db.query,payment"

traces=$("${GF[@]}" -G "$G/api/datasources/proxy/uid/tempo/api/search" \
  --data-urlencode 'q={resource.service.name="demo-checkout"}' --data-urlencode 'limit=20' |
  python -c 'import json,sys; print(len(json.load(sys.stdin).get("traces", [])))')
check "TraceQL search finds the demo service's traces" "$(yes_if "[ ${traces:-0} -gt 0 ]")" yes

echo "== dashboards"
want_boards=$(ls "$HERE"/dashboards/*.json | wc -l | tr -d ' ')
check "dashboards loaded in the Logging POC folder"   "$("${GF[@]}" "$G/api/search?type=dash-db&tag=logging-poc" | python -c 'import json,sys; print(len(json.load(sys.stdin)))')" "$want_boards"
if out=$(python "$HERE/dashboards/check_queries.py" "$G" admin "$ADMIN_PASSWORD"); then
  pass "$(echo "$out" | head -1)"
else
  fail "$(echo "$out" | head -1)"
fi
echo "$out" | tail -n +2

echo
if [ "$failures" -eq 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; exit 1; fi
