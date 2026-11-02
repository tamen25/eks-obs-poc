# Deploying the logging pipeline to EKS

This deploys Fluent Bit, Loki and Grafana into an existing EKS cluster with Terraform, and
proves that a log line written by a pod can be read back in Grafana. It is a pipeline test:

```
 every node                  namespace "loki"                    namespace "grafana"
 Fluent Bit (DaemonSet)  ─►  loki-gateway ─► Loki ─► one EBS  ◄─ Grafana
 namespace "logging"         TLS, Basic Auth         volume
```

Loki keeps its logs on one EBS volume. Terraform creates no S3 bucket, KMS key or IAM role.
There are no traces and no metrics.

> **Status:** this stack has not been applied to a real EKS cluster yet. The Terraform and
> verification steps were run on a local kind cluster, with an AWS emulator answering the cluster
> and VPC lookups. The `aws` commands have not been run. See [What was tested](#what-was-tested).

Commands are bash (Linux, WSL or Git Bash on Windows), run from a shell that can reach the
cluster's API endpoint.

## What it costs

About $0.012 an hour (roughly $9 a month) for 110 GiB of gp3 volumes at us-east-1 list prices,
plus data transfer when agents send to Loki across zones. If the cluster has no spare capacity,
add the cost of a node. Run [Remove everything](#7-remove-everything) when you are done.

## 1. Tools

| Tool | Version | Used for |
|---|---|---|
| Terraform | 1.9 or later, below 2.0 (tested with 1.13.3) | the deployment |
| AWS CLI | v2 | access checks; Terraform also runs `aws eks get-token`, so it must be on PATH |
| kubectl | within one minor version of the cluster | access checks and verification |
| curl | any | reading the test line back |

The Helm CLI is not needed: Terraform installs the charts itself.

```bash
terraform version
aws --version
kubectl version --client
```

## 2. Check access

Set these once. Everything below uses them.

```bash
export CLUSTER=<your cluster name>
export AWS_REGION=<your region>
```

**AWS: who am I, and can I see the cluster?**

```bash
aws sts get-caller-identity
aws eks describe-cluster --name "$CLUSTER" --query 'cluster.{status:status,version:version}'
aws ec2 describe-vpcs --max-items 1 --query 'Vpcs[].VpcId'
```

The cluster should be `ACTIVE`. Terraform reads the cluster and its VPC, so it needs these read
permissions and nothing else in AWS.

**Kubernetes: can I administer the cluster?**

```bash
aws eks update-kubeconfig --name "$CLUSTER"
kubectl get nodes -o wide
kubectl auth can-i '*' '*' --all-namespaces
```

The last command must print `yes`. The charts create cluster roles, so this needs cluster-admin
through an EKS access entry. Terraform uses the same AWS identity through `aws eks get-token`. If
you use a different role for the cluster, set `kubernetes_auth_role_arn` in step 4.

`OS-IMAGE` should be Amazon Linux 2023. Bottlerocket nodes cannot share their journal this way,
so on those set `fluent_bit = { node_logs = { enabled = false } }` in step 4.

**The cluster has what the stack needs:**

```bash
# The EBS CSI driver creates the volumes. Must exist.
kubectl get csidriver ebs.csi.aws.com

# Should show enableNetworkPolicy "true". Without it the pipeline still works, but the
# NetworkPolicies are not enforced and the plan prints a warning.
aws eks describe-addon --cluster-name "$CLUSTER" --addon-name vpc-cni --query addon.configurationValues
```

**Nothing is in the way:**

```bash
# All three must say NotFound. Terraform creates these and fails if they exist.
kubectl get namespace loki logging grafana

# Must print nothing, or the Helm installs clash with what is already there.
kubectl get clusterrole,clusterrolebinding,storageclass -o name | grep -E 'fluent-bit|loki|grafana|pod-lifecycle|logging-gp3-encrypted'
```

**There is room:** the stack requests about 2.2 vCPU and 5.6 GiB of memory for Loki, its caches,
the gateway and Grafana, plus 0.1 vCPU and 128 MiB per node for the agent. Check with:

```bash
kubectl describe nodes | grep -A8 'Allocated resources'
```

## 3. Copy the stack to a new folder

Run this from the `eks-logging` folder. It leaves out tests, local state and caches.

```bash
mkdir -p ../logging-deploy
tar --exclude=.terraform --exclude=tests --exclude=integrations --exclude=images \
  --exclude='*.tfstate*' --exclude=tfplan -cf - . | tar -xf - -C ../logging-deploy
cd ../logging-deploy
```

## 4. Set the values

Create `terraform.tfvars`:

```hcl
cluster_name = "<your cluster name>"
aws_region   = "<your region>"
environment  = "dev"

grafana = { enabled = true }
```

Only the first three are required. Grafana is off unless you set that last line. Everything else
keeps its default: one Loki replica, 7 days of logs and a 100 GiB volume, and TLS and
NetworkPolicies on. For a small test you can shrink the volume and retention:

```hcl
loki = { persistence_size = "20Gi", retention_period = "72h" }
```

`terraform.tfvars.example` lists the other settings.

**Terraform state** stays in this folder by default, which is fine for a test run by one person.
It holds the Loki and Grafana passwords and TLS private keys in plain text, so keep the folder
private and do not commit it. To share the state, copy `backend.tf.example` to `backend.tf` and
point it at a bucket you already have. The stack does not create that bucket.

## 5. Deploy

```bash
terraform init
terraform plan -out tfplan
```

Read the plan before applying. Expect `Plan: 35 to add, 0 to change, 0 to destroy`. This command
should print nothing, which confirms that no AWS resource will be created:

```bash
terraform show -no-color tfplan | grep -E '^ *# .*aws_[a-z0-9_]+\.[a-z_]+.* will be created'
```

Then apply:

```bash
terraform apply tfplan
```

Terraform waits for each chart to become Ready, up to 15 minutes for Loki. If it fails, see
[Troubleshooting](#troubleshooting).

## 6. Verify the pipeline

**Everything is running.** All pods should be `Running` and Ready, and both volumes `Bound`:

```bash
kubectl -n loki get pods,pvc
kubectl -n logging get pods
kubectl -n grafana get pods,pvc
```

You should see `loki-0`, `loki-chunks-cache-0`, `loki-results-cache-0` and two `loki-gateway`
pods in `loki`; a `fluent-bit` pod per node, `fluent-bit-events` and `pod-lifecycle` in `logging`;
and `grafana` in `grafana`.

**Open a connection to Grafana.** Leave this running in the background, or in a second terminal:

```bash
export GRAFANA_PASSWORD=$(kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n grafana port-forward svc/grafana 3000:3000 &
```

**Grafana can reach Loki:**

```bash
curl -s -u "admin:$GRAFANA_PASSWORD" http://127.0.0.1:3000/api/datasources/uid/loki/health
```

Expect `"status":"OK"`.

**A pod's lines reach Grafana.** This writes exactly 100 lines, waits, and counts them:

```bash
kubectl run pipeline-test --image=busybox:1.37 --restart=Never --command -- \
  sh -c 'for i in $(seq 1 100); do echo "pipeline-test line=$i"; done; sleep 3600'
kubectl wait --for=condition=Ready pod/pipeline-test --timeout=120s
sleep 20

loki_query() {
  curl -s -u "admin:$GRAFANA_PASSWORD" -G \
    http://127.0.0.1:3000/api/datasources/proxy/uid/loki/loki/api/v1/query \
    --data-urlencode "query=$1"
}

loki_query 'sum(count_over_time({namespace="default", container="pipeline-test"} [10m]))' | grep -o '"value":\[[^]]*\]'
```

Expect `"100"` as the second number: **that is the pipeline working.** Anything less, or no
output, means lines were lost or have not arrived yet. Run the query again after a minute.

**Kubernetes events and node logs arrive too.** Delete the test pod and look for its events,
then the kubelet and containerd journals:

```bash
kubectl delete pod pipeline-test --now
sleep 15

loki_query 'sum by (reason) (count_over_time({job="kubernetes-events", namespace="default"} | object="pipeline-test" [10m]))' | grep -oE '"reason":"[A-Za-z]+"'
loki_query 'sum by (unit) (count_over_time({job="node"} [10m]))' | grep -oE '"unit":"[^"]+"'
```

Expect the reasons `Scheduled`, `Started` and `Killing` (`Pulled` and `Created` too), and the
units `kubelet.service` and `containerd.service`. On EKS `kernel` should appear as well. kind
nodes have no kernel log, so that has not been seen.

Event lines do not contain the pod's name, because Fluent Bit moves it into metadata. Select it
with `| object="pod-name"` as above. A text search such as `|= "pod-name"` finds only the few
events whose message happens to mention it.

**The agents are not complaining:**

```bash
kubectl -n logging logs ds/fluent-bit --tail=200 | grep -iE 'error|warn'
```

Expect no output. A few retries while Loki was starting are normal.

**See it in the UI.** Open <http://127.0.0.1:3000>, log in as `admin` with `$GRAFANA_PASSWORD`, go
to **Explore**, pick **Loki**, and run `{namespace="logging"}`.

Stop the port-forward when you finish:

```bash
kill %1
```

## 7. Remove everything

Note the volume IDs first, so you can confirm that AWS deleted them:

```bash
kubectl get pv -o custom-columns=NAMESPACE:.spec.claimRef.namespace,VOLUME:.spec.csi.volumeHandle | grep -E 'loki|grafana'
```

```bash
terraform destroy
```

Then check:

```bash
# All three must say NotFound.
kubectl get namespace loki logging grafana

# Must fail with InvalidVolume.NotFound, once for the volumes noted above.
aws ec2 describe-volumes --volume-ids <volume id> <volume id>
```

**This deletes every log**, along with the namespaces and volumes. There is no second copy.

## Changing something later

Edit `terraform.tfvars`, then run `terraform plan -out tfplan`, read it, and run
`terraform apply tfplan`.

**Turning a component off deletes its data.** With `grafana = { enabled = false }`, Terraform
uninstalls the chart and deletes the `grafana` namespace, everything else in that namespace, and
Grafana's volume. So dashboards made in the UI are gone. Loki and Fluent Bit keep running.
Turning it back on creates a new, empty Grafana with a new password. Doing the same to Loki
deletes every log.

Do not keep anything of your own in `loki`, `logging` or `grafana`: Terraform deletes it with the
namespace.

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| `Unauthorized` or `the server has asked for the client to provide credentials` | The AWS identity has no EKS access entry | Add one with cluster-admin rights, or set `kubernetes_auth_role_arn` |
| `no cached repo found` while planning | The Helm CLI is installed and its index cache was cleared | `helm repo update`, then plan again |
| `namespaces "loki" already exists` | An earlier install or another team's stack | Find out what owns it before changing anything |
| Helm says a resource `exists and cannot be imported` | Another Fluent Bit, Loki or Grafana on the cluster owns a cluster-wide resource | Remove the other install, or do not deploy here |
| Loki's apply runs for 15 minutes, then fails; `loki-0` is `Pending` | Volume not created, or no room on a node | `kubectl -n loki describe pod loki-0` and `kubectl -n loki describe pvc`; check the EBS CSI driver and its IAM role, and node capacity |
| `Warning: ... enableNetworkPolicy` in the plan | The VPC CNI does not enforce NetworkPolicies | Safe for this test; enable it in the add-on configuration before relying on them |
| `fluent-bit` pods not Ready | Agents cannot push to Loki | `kubectl -n logging logs ds/fluent-bit --tail=50`, then check that the `loki-gateway` pods are Ready |
| The count is below 100 | Lines not delivered yet, or lost | Wait a minute and run it again; then check the agent logs |
| No `job="node"` logs | Different journal path, or Bottlerocket | `journal_path` defaults to `/var/log/journal`, which is right for AL2023 but has not been run on it |
| Loki stops accepting logs after some days | The volume is full | Raise `loki.persistence_size`, or shorten `loki.retention_period` |

## What was tested

On a kind cluster (Kubernetes 1.34, two nodes), with [moto](https://github.com/getmoto/moto)
answering the AWS lookups:

- The fresh plan had 34 resources and none from AWS. EKS adds the StorageClass, making 35.
- `tests/e2e/check.sh` passed: 41 of 41 checks, covering the gateway's TLS and password, evicted
  and short-lived pods, cluster-wide collection and NetworkPolicies. All lines were still there
  after Loki's pod restarted.
- The 100-line test above returned 100 through Grafana. Events and kubelet and containerd logs
  arrived.
- Grafana off and on, then `terraform destroy`, behaved as described. Destroy took 139 seconds
  and left no namespaces or volumes.
- The `kubectl` checks in step 2 ran on kind for their syntax. Their answers there say nothing
  about your cluster, and kind has no EBS CSI driver.

**Not tested, because no real EKS cluster was used:**

- Any of the `aws` commands in this document, and `aws eks get-token`.
- The EBS CSI driver creating and deleting real volumes, including the `InvalidVolume.NotFound`
  check. kind uses a local-path provisioner.
- The `Plan: 35 to add` count, which is worked out, not seen.
- VPC CNI enforcing the NetworkPolicies.
- Journal logs on AL2023 nodes, and kernel logs anywhere.
- Timing and resource use at real log volumes.

So expect that the first real run may find something. If it does, the fix belongs here too.
