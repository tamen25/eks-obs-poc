#!/usr/bin/env bash
# Local POC on kind: Loki, Tempo, Grafana, Fluent Bit and an OpenTelemetry collector, all in
# one cluster, nothing outside it.
#
#   ./run.sh up       create the kind cluster logging-poc
#   ./run.sh apply    terraform apply into it
#   ./run.sh check    run check.sh against the deployed POC
#   ./run.sh scenarios  run the test scenarios (evictions, OOM, crash loops, burst...)
#   ./run.sh grafana  port-forward Grafana to http://127.0.0.1:23030 (no login)
#   ./run.sh down     delete the cluster and the Terraform state
#
# Needs: docker, kind, kubectl, terraform, curl, python3.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLUSTER=logging-poc
CONTEXT="kind-$CLUSTER"

up() {
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --config "$HERE/kind-config.yaml"
  echo "kind cluster $CLUSTER is up"
}

apply() {
  terraform -chdir="$HERE" init -input=false >/dev/null
  terraform -chdir="$HERE" apply -auto-approve -input=false "$@"
}

grafana() {
  echo "http://127.0.0.1:23030, no login (Ctrl+C to stop)"
  kubectl --context "$CONTEXT" -n observability port-forward svc/grafana 23030:80 --address 127.0.0.1
}

down() {
  kind delete cluster --name "$CLUSTER" || true
  rm -rf "$HERE"/terraform.tfstate*
}

case "${1:-}" in
  up) up ;;
  apply) shift; apply "$@" ;;
  check) bash "$HERE/check.sh" ;;
  scenarios) bash "$HERE/scenarios.sh" ;;
  grafana) grafana ;;
  down) down ;;
  *) echo "usage: $0 up|apply|check|scenarios|grafana|down" >&2; exit 2 ;;
esac
