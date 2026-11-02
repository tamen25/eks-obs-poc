#!/usr/bin/env bash
# Offline verification for the stack. Nothing here calls AWS or a cluster.
#
#   1. terraform fmt / validate / tflint
#   2. terraform test in every module and integration that has tests, plus the root
#      (providers mocked)
#   3. render the Helm values and Fluent Bit configs (tests/render)
#   4. helm template against the pinned charts (Loki's chart has a strict JSON schema)
#   5. Pod Security "restricted" check on the Loki and Grafana namespaces
#   6. kubeconform on every rendered manifest
#   7. checkov on the Terraform code and the rendered manifests
#
# Needs: terraform >= 1.9, tflint, helm, python3 with PyYAML, kubeconform, checkov.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
RENDER="$ROOT/tests/render"
LOKI_CHART_VERSION=20.0.2
FLUENT_BIT_CHART_VERSION=0.58.3
GRAFANA_CHART_VERSION=14.2.0
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.34.0}
# Override when the tools are not on PATH under these names.
PYTHON=${PYTHON:-python3}
CHECKOV=${CHECKOV:-checkov}
KUBECONFORM=${KUBECONFORM:-kubeconform}

step() { printf '\n== %s\n' "$*"; }

step "terraform fmt"
terraform fmt -check -recursive

step "terraform validate"
terraform init -backend=false -input=false >/dev/null
terraform validate
for dir in integrations/*/; do
  echo "-- $dir"
  (cd "$dir" && terraform init -backend=false -input=false >/dev/null && terraform validate)
done

step "tflint"
tflint --init >/dev/null
tflint --recursive

step "terraform test"
for dir in modules/*/ modules/*/*/ integrations/*/; do
  if [ -d "$dir/tests" ]; then
    echo "-- $dir"
    (cd "$dir" && terraform init -backend=false -input=false >/dev/null && terraform test)
  fi
done
echo "-- root"
terraform test

step "render values"
(cd "$RENDER" && terraform init -input=false >/dev/null && terraform apply -auto-approve -input=false >/dev/null)

step "helm template"
helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana-community fluent >/dev/null
mkdir -p "$RENDER/manifests"
render() { # release chart version namespace values-file output
  helm template "$1" "$2" --version "$3" --namespace "$4" -f "$RENDER/out/$5" >"$RENDER/manifests/$6"
  echo "rendered $6"
}
render loki grafana-community/loki "$LOKI_CHART_VERSION" loki loki-monolithic.values.yaml loki-monolithic.yaml
render loki grafana-community/loki "$LOKI_CHART_VERSION" loki loki-filesystem.values.yaml loki-filesystem.yaml
render loki grafana-community/loki "$LOKI_CHART_VERSION" loki loki-distributed.values.yaml loki-distributed.yaml
render fluent-bit fluent/fluent-bit "$FLUENT_BIT_CHART_VERSION" logging fb-agent.values.yaml fb-agent.yaml
render fluent-bit fluent/fluent-bit "$FLUENT_BIT_CHART_VERSION" logging fb-agent-keep.values.yaml fb-agent-keep.yaml
render fluent-bit-events fluent/fluent-bit "$FLUENT_BIT_CHART_VERSION" logging fb-events.values.yaml fb-events.yaml
render grafana grafana-community/grafana "$GRAFANA_CHART_VERSION" grafana grafana.values.yaml grafana.yaml

step "pod security (restricted) for the loki and grafana namespaces"
"$PYTHON" scripts/check_pod_security.py \
  "$RENDER/manifests/loki-monolithic.yaml" "$RENDER/manifests/loki-filesystem.yaml" "$RENDER/manifests/loki-distributed.yaml" \
  "$RENDER/manifests/grafana.yaml" "$RENDER/manifests/fb-events.yaml"

step "kubeconform"
"$KUBECONFORM" -strict -summary -kubernetes-version "$KUBERNETES_VERSION" -ignore-missing-schemas "$RENDER"/manifests/*.yaml

step "checkov"
# all-features.tfvars switches every optional module on, so none of them escapes the scan.
$CHECKOV --quiet --compact --config-file .checkov.yaml --directory . --var-file tests/all-features.tfvars \
  --skip-path tests/render/out --skip-path tests/render/manifests --framework terraform
$CHECKOV --quiet --compact --config-file .checkov.yaml --directory "$RENDER/manifests" --framework kubernetes

echo
echo "All checks passed."
