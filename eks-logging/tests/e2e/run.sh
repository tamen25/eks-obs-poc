#!/usr/bin/env bash
# End-to-end test on a local kind cluster, with moto standing in for AWS.
#
#   tests/e2e/run.sh up       create the kind cluster and moto, register a fake EKS cluster
#   tests/e2e/run.sh apply    copy the stack to .work, swap in providers.tf, terraform apply
#   tests/e2e/run.sh check    run check.sh against the deployed stack
#   tests/e2e/run.sh down     delete the kind cluster and moto
#
# TFVARS=e2e-filesystem.tfvars tests/e2e/run.sh apply deploys Loki on its volume, without S3;
# check.sh sees which backend is deployed. moto still answers the cluster and VPC lookups.
#
# Needs: docker, kind, kubectl, terraform, aws CLI, curl, python3.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK="$HERE/.work"
CLUSTER=eks-logging-e2e
MOTO=eks-logging-moto
MOTO_IMAGE=motoserver/moto:5.2.3
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
MOTO_URL=https://127.0.0.1:25000
CERTS="$HERE/.certs"
# moto serves TLS with a throwaway certificate: the stack's bucket policy denies plain HTTP,
# and moto enforces bucket policies.
export AWS_CA_BUNDLE="$CERTS/moto.crt"

up() {
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --config "$HERE/kind-config.yaml"
  if [ ! -f "$CERTS/moto.crt" ]; then
    mkdir -p "$CERTS"
    # MSYS_NO_PATHCONV keeps -subj intact but also stops Git Bash converting the output
    # paths, so hand openssl a Windows path; cygpath is absent elsewhere and not needed.
    out=$(cygpath -m "$CERTS" 2>/dev/null || echo "$CERTS")
    # The S3 Control SAN covers "<account>.s3control.127.0.0.1.nip.io" (see providers.tf).
    MSYS_NO_PATHCONV=1 openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -days 7 -subj "/CN=eks-logging-moto" -keyout "$out/moto.key" -out "$out/moto.crt" \
      -addext "subjectAltName=DNS:eks-logging-moto,DNS:localhost,IP:127.0.0.1,DNS:*.s3control.127.0.0.1.nip.io"
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$MOTO"; then
    docker rm -f "$MOTO" >/dev/null 2>&1 || true
    cert_dir=$(cygpath -w "$CERTS" 2>/dev/null || echo "$CERTS")
    MSYS_NO_PATHCONV=1 docker run -d --name "$MOTO" --network kind -p 127.0.0.1:25000:5000 \
      -v "$cert_dir:/certs:ro" "$MOTO_IMAGE" -H 0.0.0.0 -p 5000 -c /certs/moto.crt -k /certs/moto.key >/dev/null
  fi
  for _ in $(seq 30); do curl -sf --cacert "$CERTS/moto.crt" "$MOTO_URL/moto-api/" >/dev/null && break; sleep 1; done
  if ! aws --endpoint-url "$MOTO_URL" eks describe-cluster --name e2e-cluster >/dev/null 2>&1; then
    vpc=$(aws --endpoint-url "$MOTO_URL" ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
    subnets=$(aws --endpoint-url "$MOTO_URL" ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" \
      --query 'Subnets[0:2].SubnetId' --output text | tr '\t' ',')
    aws --endpoint-url "$MOTO_URL" eks create-cluster --name e2e-cluster \
      --role-arn arn:aws:iam::123456789012:role/eks --resources-vpc-config "subnetIds=$subnets" >/dev/null
  fi
  echo "kind cluster $CLUSTER and moto are up"
}

apply() {
  rm -rf "$WORK" && mkdir -p "$WORK"
  (cd "$ROOT" && tar --exclude=.terraform --exclude=tests --exclude=integrations --exclude='*.tfstate*' -cf - .) |
    (cd "$WORK" && tar -xf -)
  cp "$HERE/providers.tf.e2e" "$WORK/providers.tf"
  cp "$HERE/storage_override.tf.e2e" "$WORK/modules/loki/storage/e2e_override.tf"
  cp "$HERE/${TFVARS:-e2e.tfvars}" "$WORK/terraform.tfvars"
  # Terraform on Windows needs a Windows path; cygpath is absent elsewhere and not needed.
  echo "moto_ca_bundle = \"$(cygpath -m "$CERTS/moto.crt" 2>/dev/null || echo "$CERTS/moto.crt")\"" >> "$WORK/terraform.tfvars"
  # Keep state from earlier runs so apply updates in place.
  [ -f "$HERE/terraform.tfstate" ] && cp "$HERE/terraform.tfstate" "$WORK/"
  terraform -chdir="$WORK" init -input=false >/dev/null
  status=0
  terraform -chdir="$WORK" apply -auto-approve -input=false "$@" || status=$?
  cp "$WORK/terraform.tfstate" "$HERE/terraform.tfstate"
  return $status
}

down() {
  # No terraform destroy: everything it would remove lives in the kind cluster or in moto,
  # and deleting those takes seconds where a destroy walks every resource for minutes (and
  # retries forever once moto is gone).
  kind delete cluster --name "$CLUSTER" || true
  docker rm -f "$MOTO" >/dev/null 2>&1 || true
  rm -rf "$WORK" "$CERTS" "$HERE"/terraform.tfstate*
}

case "${1:-}" in
  up) up ;;
  apply) shift; apply "$@" ;;
  check) bash "$HERE/check.sh" ;;
  down) down ;;
  *) echo "usage: $0 up|apply|check|down" >&2; exit 2 ;;
esac
