# EKS logging stack: Loki, Fluent Bit and (optionally) Grafana

Terraform that installs a log pipeline into an existing EKS cluster. Loki, Fluent Bit and
Grafana are separate components with their own `enabled` switch, so you can run any
combination: the full pipeline, Loki and Fluent Bit with Amazon Managed Grafana as the UI
(the default), Fluent Bit alone pushing to a central Loki, or Loki alone.

It is meant as the cluster's only log pipeline: every container on every node (init
containers, sidecars, crash loops, system pods), plus the kubelet, container runtime and
kernel logs from each node's journal. See [What gets collected](#what-gets-collected). It
also carries over what the eviction lab in the parent folder measured (`../FINDINGS.md`), so
pods that are evicted, drained, preempted or force-deleted keep their last log lines. See
[Evicted pods](#evicted-pods).

Loki keeps its logs on one EBS volume by default, with no S3 bucket, KMS key or IAM role. S3
with storage tiers is one setting away. See [Where logs live](#where-logs-live).

Nothing in this folder has been applied to a real AWS account or EKS cluster yet. See
[What was verified](#what-was-verified) before the first apply.

## Layout

```
eks-logging/
  main.tf, variables.tf, ...        root: wires the components together
  modules/
    loki/                           component: gateway TLS, Helm, NetworkPolicies; with S3 also KMS, tiers, IAM role
      storage/                        S3 only: buckets, lifecycle tiers (hot -> warm -> archive)
      values/                         pure module: Helm values (tested offline)
    fluent-bit/                     component: agent, event collector, aggregator, log-keeper, NetworkPolicies
      values/                         pure module: Fluent Bit config and Helm values
    grafana/                        component: Grafana, datasources, dashboards, CloudWatch role, NetworkPolicies
      values/                         pure module: Helm values
    pod-lifecycle/                  watcher that logs pod terminal states (runs with Fluent Bit)
    namespaces/                     namespaces with Pod Security labels, encrypted gp3 StorageClass
    workload-identity/              building block: IAM role with IRSA trust or a Pod Identity association
    internal-tls/                   building block: private CA and server certificates
  integrations/
    amazon-managed-grafana/         separate root: Loki datasource + dashboard in an existing AMG workspace
  images/log-keeper/                Dockerfile for the optional log-keeper
  scripts/validate.sh               offline verification
```

Each component owns everything it needs: the Loki module creates its certificate,
NetworkPolicies and, on S3, its buckets, KMS key and IAM role; the Fluent Bit module creates
the aggregator's certificate and its own policies; and so on. Turning a component off removes
all of its resources and nothing else, including its namespace and volumes. See
[Operations](#operations).

```
 every node                         namespace "logging" (Pod Security: privileged)
 ┌────────────────────────────┐
 │ fluent-bit (DaemonSet)     │──┐  tails /var/log/containers (or /var/log/keep)
 │ log-keeper (optional)      │  │  hard-links new logs so deletion does not lose them
 └────────────────────────────┘  │
   fluent-bit-events (1 pod)  ───┤  Kubernetes events (Evicted, Killing, Preempted, ...)
   pod-lifecycle (1 pod)      ───┤  pod terminal states: disruption reason, last log lines
   fluent-bit-aggregator      ◄──┘  optional: agents forward here, it pushes to Loki
          │ TLS + Basic Auth, port 8080
          ▼
 namespace "loki" (Pod Security: restricted)
   loki-gateway (nginx: auth, tenant) ─► loki
          ▲                                 │
          │ internal NLB or ALB (optional)  ▼
   Amazon Managed Grafana           filesystem (default): one EBS volume, one replica
   or in-cluster Grafana            s3: chunks bucket, Standard ─► Glacier IR ─► (Deep Archive)
                                        ruler bucket, Standard; IRSA or Pod Identity
```

Chart and image versions (pinned in `variables.tf`):

| Component | Chart | App |
|---|---|---|
| Loki | `grafana-community/loki` 20.0.2 | 3.7.9 |
| Fluent Bit | `fluent/fluent-bit` 0.58.3 | 5.1.3 |
| Grafana | `grafana-community/grafana` 14.2.0 | 13.3.0 |

The OSS Loki and Grafana charts moved from `grafana/helm-charts` to
`grafana-community/helm-charts` on 2026-03-16. `grafana/loki` now serves Grafana Enterprise
Logs, so do not point `loki.chart_repository` back at it.

## Choosing components

| You want | Set |
|---|---|
| Loki + Fluent Bit, Amazon Managed Grafana as the UI (default) | nothing; then see [Amazon Managed Grafana](#amazon-managed-grafana) |
| Everything in the cluster | `grafana = { enabled = true }` |
| Fluent Bit only, pushing to a central Loki | `loki = { enabled = false }` and `fluent_bit.loki_endpoint`, `external_loki_password` |
| Loki only (agents come from elsewhere) | `fluent_bit = { enabled = false }` |
| Loki and Fluent Bit in one namespace | `loki = { namespace = "logging" }` |
| Logs in S3 instead of on Loki's volume | `loki = { storage = { backend = "s3" } }`; see [Where logs live](#where-logs-live) |

Namespaces follow the components: only those of enabled components are created. The one that
holds the node agents enforces Pod Security `privileged`, because the agents read node files
through hostPath. Loki and Grafana namespaces enforce `restricted`. If Loki shares the agents'
namespace it works the same, but Loki's pods are then admitted under `privileged` too, so the
default keeps them apart. Every namespace warns and audits against `restricted` regardless.

## Before you start

The cluster needs these, and this stack does not install them:

- **EBS CSI driver** add-on, for Loki, Grafana and aggregator volumes.
- **An IAM OIDC provider** for the cluster (IRSA mode), or the **eks-pod-identity-agent**
  add-on (`aws_identity_mode = "pod_identity"`). Only when something needs an AWS role: Loki
  on S3, or `grafana.cloudwatch_audit`.
- **VPC CNI network policy enforcement** (`enableNetworkPolicy: "true"` in the vpc-cni add-on
  configuration). The stack creates NetworkPolicies by default and warns at plan time if the
  add-on will not enforce them.
- **AWS Load Balancer Controller** if you expose the Loki gateway (NLB or ALB) or Grafana.
- **Control plane audit logging** to CloudWatch if you turn on `grafana.cloudwatch_audit`.

The identity running Terraform needs EC2 (`DescribeVpcs`) and EKS read permissions in the
account, plus IAM, S3 and KMS when Loki is on S3, and cluster-admin in the cluster through an
EKS access entry.
Terraform gets a short-lived token from `aws eks get-token` on every run (set
`kubernetes_auth_role_arn` to assume a role for that), so the AWS CLI must be on PATH.

Tools: Terraform >= 1.9 (tested with 1.13.3), AWS CLI v2, and for `scripts/validate.sh`:
tflint, helm, kubeconform, checkov, Python 3 with PyYAML.

## Usage

[DEPLOYMENT.md](DEPLOYMENT.md) walks through a first deployment step by step with Terraform, the
AWS CLI and kubectl: access checks, proving a log line reaches Grafana, and removing it all. In
short:

1. **Remote state.** State holds the tenant password, the Grafana admin password (if
   Grafana is on) and the internal TLS private keys. Copy `backend.tf.example` to
   `backend.tf` and point it at an S3 bucket with SSE-KMS, versioning and access limited to
   the people who run this.
2. **Settings.** Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in at least
   `cluster_name`, `aws_region` and `environment`.
3. **Plan and apply.**

   ```bash
   terraform init
   terraform plan -out tfplan
   terraform apply tfplan
   ```

4. **Query the logs** in Amazon Managed Grafana (below), or in the in-cluster Grafana if you
   turned it on:

   ```bash
   kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
   kubectl -n grafana port-forward svc/grafana 3000:3000
   ```

## Where logs live

`loki.storage.backend` picks one of two:

| | `filesystem` (default) | `s3` |
|---|---|---|
| Where | one EBS volume on the Loki pod | S3 buckets with a KMS key and storage tiers |
| AWS resources created | none (the volume comes from the EBS CSI driver) | buckets, KMS key, IAM role |
| Loki replicas | 1, the only count Loki allows | 3 by default |
| Deployment mode | Monolithic only | Monolithic or Distributed |
| Default retention | 7 days | 90 days |
| Default volume | 100 GiB, holds every log | 50 GiB, holds the write-ahead log and cache |

Filesystem storage has real limits, which is why S3 stays available:

- **Loki is down while its pod restarts.** Agents buffer and retry in the meantime. An EBS
  volume lives in one availability zone, so the pod can only run on nodes in that zone; with
  no node there, Loki stays down.
- **Losing the volume loses the logs.** There is no second copy.
- **A full volume stops ingestion.** The default 100 GiB holds about 13 days of 50 GB/day raw
  logs at the 7.5 GB/day compressed rate in [Cost estimate](#cost-estimate). Nothing here alerts
  on it. Size `loki.persistence_size` and `loki.retention_period` for your volume.

**Moving to S3 later** starts with no logs. Loki reads its data through `schemaConfig`, which
has one store for the `schema_from` date, so logs on the volume are not read or copied. Set
`loki = { storage = { backend = "s3" }, retention_period = "2160h" }` and read the plan. This
switch has not been run.

## Log storage: hot, warm and archive

This section applies to `backend = "s3"`.

Loki writes chunks (the compressed log lines) and a TSDB index to S3. An S3 lifecycle rule on
the chunks bucket moves chunks through storage classes as they age:

| Tier | Storage class | Default | Loki can query it? | Read cost |
|---|---|---|---|---|
| hot | S3 Standard | first 30 days | yes | none |
| warm | Glacier Instant Retrieval | day 30 until retention ends | yes, millisecond reads | about $0.03/GB read |
| archive (optional) | Deep Archive or Glacier Flexible Retrieval | off | **no**, objects need a restore first | restore fee |

What the stack does to keep this safe:

- **Only chunks move.** The rule matches the tenant's prefix (`<tenant>/`). The TSDB index
  (`index/`), delete requests and the ruler bucket stay in Standard, because every query
  reads the index.
- **Small chunks stay in Standard.** Each transition costs a request fee. A chunk under 1 MiB
  (`min_object_size_bytes`) would cost more to move than it saves, so it is not moved. Busy
  streams make 1.5 MB chunks; quiet ones cut small chunks every 30 minutes to 2 hours.
- **Queries stop at the archive.** With the archive tier on, Loki's `max_query_lookback` ends
  one day before chunks are archived, so a query never asks S3 for an object it cannot read.
  Delete requests switch to `filter-only` (lines are hidden at query time), because rewriting
  an archived chunk would fail.
- **S3 rules are validated.** The warm class must be one Loki can read (GLACIER_IR or
  STANDARD_IA), and the archive transition must come after the warm class's minimum storage
  duration (90 days for GLACIER_IR), which S3 itself enforces.
- **Retention.** Loki's compactor deletes chunks after `loki.retention_period` (default
  2160h, 90 days). A backstop S3 rule deletes anything 30 days after that, in case the
  compactor stops.

```hcl
# One year queryable (30 days hot, 335 warm), then four more years in Deep Archive.
loki = {
  retention_period = "43800h" # 5 years
  storage = {
    tiering = {
      hot_days = 30
      archive  = { enabled = true, storage_class = "DEEP_ARCHIVE", after_days = 365 }
    }
  }
}
```

**Reading archived logs.** Restore the chunks for the time range (S3 Batch Operations with a
restore job, bulk tier, about 48 hours for Deep Archive), then raise the query window for the
duration with `loki.extra_values_yaml` (`loki.limits_config.max_query_lookback`). Finding the
chunks for a date range takes the TSDB index; the lab did not test a restore.

**Is it worth it?** At us-east-1 list prices (Standard $0.023, Glacier IR $0.004 per GB-month,
Glacier IR transitions $0.02 per 1,000 objects, 90-day minimum), with 7.5 GB of compressed
chunks per day in 1 MiB objects:

| Retention | All Standard | Hot 30 days + Glacier IR | Saving |
|---|---|---|---|
| 90 days (default) | about $16/month | about $12/month | small: Glacier IR bills 90 days even for 60 days of use, plus transition fees |
| 1 year | about $63/month | about $20/month | about $43/month |

The longer the retention, the more it saves. Below about 45 warm days it costs more than
Standard; the stack warns at plan time when that happens. Queries over warm data add $0.03 per
GB that the chunk cache does not already hold. Check current prices for your region.

## Networking

NetworkPolicies are on by default and generated from what is deployed. You do not list node
or pod CIDRs:

| Pods | Ingress allowed | Port |
|---|---|---|
| Loki (all components) | other Loki pods | any (memberlist, gRPC, HTTP, memcached) |
| Loki gateway | Fluent Bit agent, event collector and aggregator pods; Grafana pods (if on); `extra_loki_client_namespaces` | 8080 |
| Loki gateway, when exposed through an NLB or ALB | the cluster VPC's CIDRs, read from AWS | 8080 |
| Fluent Bit aggregator | agent pods | 24224 |
| Grafana | its ingress (VPC CIDRs when the ALB ingress is on), `grafana_ingress_*` | 3000 |
| Loki, agents, aggregator, Grafana | `monitoring_namespaces` | metrics ports |
| everything else in these components | nothing | |

Every policy selects one component's pods by label, so the rules are the same whether
components share a namespace or not. Kubelet health probes need no rule: the VPC CNI admits
traffic from the node itself. Service ports equal container ports (8080, 3000, 24224), which
the VPC CNI network policy agent requires. Egress is not restricted (see `SECURITY.md`).

## Amazon Managed Grafana

The default leaves the in-cluster Grafana off. To query Loki from an AMG workspace:

1. **Network.** Give the workspace a VPC connection to the cluster's VPC (or one routed to
   it), with a security group that allows outbound TCP 8080 (NLB) or 443 (ALB).
2. **Expose the gateway** inside the VPC, either way:

   ```hcl
   # Internal NLB, TLS passes through to the gateway's own certificate.
   loki = {
     gateway = {
       service = {
         type = "LoadBalancer"
         annotations = {
           "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
           "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
           "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
         }
       }
       extra_dns_names = ["loki.internal.example.com"] # private DNS record -> the NLB
     }
   }
   ```

   or an internal ALB with an ACM certificate through `loki.gateway.ingress` (then the
   workspace needs no private CA).
3. **Add the datasource and dashboard** with the integration root:

   ```bash
   cd integrations/amazon-managed-grafana
   # A short-lived token for a service account with the Admin role.
   aws grafana create-workspace-service-account --workspace-id g-xxxxxxxxxx \
     --grafana-role ADMIN --name terraform
   aws grafana create-workspace-service-account-token --workspace-id g-xxxxxxxxxx \
     --service-account-id <id> --name tf-run --seconds-to-live 3600
   export TF_VAR_grafana_token=<key from the output>
   export TF_VAR_loki_password=$(terraform -chdir=../.. output -raw loki_tenant_password)
   cp terraform.tfvars.example terraform.tfvars   # workspace ID, Loki URL, user, CA
   terraform init && terraform apply
   ```

   The root stack's `amazon_managed_grafana` output gives the URL and user, and says whether
   the CA (`loki_ca_cert_pem` output) is needed. The password and CA go into Grafana's
   encrypted `secureJsonData`, never into the readable datasource settings.

## Controlling endpoints

| What | Variable | Default |
|---|---|---|
| Where agents push | `fluent_bit.loki_endpoint` (+ `external_loki_password`) | this stack's gateway, `https://loki-gateway.loki.svc.cluster.local:8080` |
| Where the in-cluster Grafana queries | `grafana.loki_datasource_url` | the same gateway |
| Loki inside the VPC (AMG, other clusters) | `loki.gateway.service` + `extra_dns_names` (NLB) or `loki.gateway.ingress` (ALB) | cluster-internal only |
| Grafana outside the cluster | `grafana.ingress`, `grafana.root_url` | off |
| S3 API endpoint | `loki.storage.s3_endpoint` | AWS default for the region |
| Bucket access only through VPC endpoints | `loki.storage.allowed_vpc_endpoint_ids` | not restricted |
| Image registry (pull-through cache, air gap) | `image_registry_mirror`, `fluent_bit.image.repository`, `fluent_bit.log_keeper.image`, `pod_lifecycle.image` | public registries |

```hcl
# Ship this cluster's logs to a central Loki instead of running one here.
loki = { enabled = false }
fluent_bit = {
  loki_endpoint = {
    host        = "loki.logging.internal.example.com"
    port        = 443
    tenant_id   = "team-payments" # sent as X-Scope-OrgID
    username    = "team-payments"
    ca_cert_pem = ""              # a private CA, or empty for the system bundle
  }
}
external_loki_password = "..." # from your secret store, for example TF_VAR_external_loki_password
```

## What gets collected

The agent DaemonSet runs on every node, tolerates every taint, and reads two sources.

**Container logs**: every file under `/var/log/containers`, which the kubelet creates for
each container in every namespace. Nothing is excluded unless you list it in
`fluent_bit.exclude_namespaces`. Each line is sent exactly as the container wrote it (JSON
stays JSON, no wrapper fields), with these labels and structured metadata:

| Stream labels | Structured metadata |
|---|---|
| `cluster`, `namespace`, `container`, `service_name` (added by Loki), your `extra_labels` | `pod`, `pod_uid`, `node`, `stream` (`stdout` or `stderr`) |

Pod names stay out of the labels on purpose: they change on every rollout and would multiply
Loki's streams. Filter with `| pod="..."` instead.

**Node logs** (`fluent_bit.node_logs`, on by default): the `kubelet.service` and
`containerd.service` journal units and kernel messages, as `job="node"` streams labelled
`unit` (`kubelet.service`, `containerd.service` or `kernel`), with `node` and `priority` as
metadata. These hold what no container log does: image pull failures, failed mounts,
probe failures, OOM kills, eviction decisions.

**Kubernetes events** come from a separate one-replica event collector, as
`job="kubernetes-events"` streams labelled `namespace`, `reason` and `kind`.

How the edge cases are handled:

| Case | Handling |
|---|---|
| Lines over 16 KB | The runtime splits them; the CRI parser joins the parts back into one line |
| Lines over 256 KB | Loki keeps the first 256 KB (`max_line_size_truncate`) and the lines after it still arrive |
| Log rotation (kubelet, 10 MiB) | Rotated files are read to the end; position kept in a DB on the node across agent restarts |
| Crash-looping containers | New files found every 0.5s: the first attempt's log exists for only about 1s |
| Pods deleted, evicted or short-lived | Deleted files read for 300s; see [Evicted pods](#evicted-pods) |
| Agent restart | Resumes from the DB position, no re-reading, no gaps for files still on disk |

## Evicted pods

Every way a pod can disappear, what happens to its logs on the node, and what in this stack
covers it. The measurements are from the lab on kind (`../FINDINGS.md`).

| Scenario | What the node does | Covered by | Default |
|---|---|---|---|
| Kubelet eviction (memory, disk, ephemeral-storage pressure) | deletes the log file about 3s after eviction | file discovery every 0.5s (`refresh_interval`), deleted files read for 300s (`rotate_wait`), `Evicted` event with the reason | on |
| Eviction API (drain, Karpenter consolidation, autoscaler) | deletes the files with the pod; no `Evicted` event, only `Killing` | same, plus pod-lifecycle records `disruption=EvictionByEvictionAPI` and the last lines | on |
| Scheduler preemption, taint-based eviction | graceful delete | `Preempted` / `TaintManagerEviction` events, pod-lifecycle disruption reason | on |
| Pod lives and dies within seconds | files may exist for about 1s | 2s discovery caught 8 of 8 in the lab; log-keeper makes it independent of timing | on / opt-in |
| Container crash-looping | the first attempt's log is deleted about 1s later, when the immediate restart exits | 0.5s discovery: 0 of 90 first attempts lost on kind, where 2s lost up to half; log-keeper makes it independent of timing | on / opt-in |
| Force delete (`--grace-period=0 --force`) | files gone about 8s later; the pod is gone from the API before the agent asks for its metadata | discovery + `rotate_wait`; namespace, pod and container taken from the file name when the API has nothing (the e2e test found lines arriving unlabelled without this); log-keeper holds the file | on / opt-in |
| Agent behind during a log burst | file deleted while unread | `rotate_wait: 300` read 300,072 of 300,072 lines where 30s lost about half; filesystem buffer instead of pausing the input | on |
| Agent restarted during an eviction storm | open handle on a deleted file is lost | log-keeper (300,097 of 300,097 delivered vs 96,805 without); DB on hostPath and `read_from_head` for live files | opt-in |
| Agent evicted together with the pods | node pressure or `NoExecute` taint takes the shipper too | `system-node-critical` priority, tolerates every taint | on |
| Node drained or spot reclaim | agent gets SIGTERM | flushes for 30s (`grace`), unsent data stays in the node buffer | on |
| Node crash or spot loss without a drain | the node and its buffer are gone | aggregator: 47 lines lost (about 0.5s) with Loki down beforehand, vs 506 without | opt-in |
| Loki slow or down | pushes fail with 429/5xx | unlimited retries, disk buffer on the node (or the aggregator's volumes) | on |
| Last line is a 1 MB stack trace | Loki would drop it and report success | `max_line_size_truncate`: the start of the line is kept | on |
| `kubectl logs` after the file is gone | fails | pod-lifecycle ships the termination message: set `terminationMessagePolicy: FallbackToLogsOnError` on your containers | on, needs your pod spec |

What is not covered: logs a pod writes in the last moment before a node loses power, and
logs the kubelet never wrote to disk. Turn on `fluent_bit.log_keeper` and
`fluent_bit.aggregator` where losing those few seconds matters.

The "Evicted pod logs" dashboard (in-cluster Grafana, or AMG through the integration) shows
the events, the pod-lifecycle records and the pods' last lines side by side.

## Operations

- **Rotate the tenant password**: increase `loki.credentials_revision` and apply. Loki, the
  agents and Grafana get the new value in the same apply; agents retry the few pushes rejected
  while pods restart. Re-run the AMG integration with the new password.
- **Certificates**: server certificates last a year and are replaced on the first apply within
  30 days of expiry (`internal_tls.early_renewal_hours`). Apply at least monthly, or move to
  cert-manager. The NLB path means AMG trusts the CA, which lasts 5 years.
- **Never change `loki.schema_from`** after the first deployment. Add a new schema period
  through `loki.extra_values_yaml` instead.
- **Changing tiers** applies to objects by age from then on; chunks already in Glacier IR do
  not move back.
- **Upgrading charts**: change the version variables, run `scripts/validate.sh`, read the
  plan. Grafana's
  [upgrade guide](https://grafana.com/docs/loki/latest/setup/upgrade/upgrade-to-community/)
  lists breaking changes.
- **Do not roll the agent DaemonSet during an incident.** A restart drops open handles on logs
  that are already deleted. log-keeper removes that risk.
- **Turning a component off deletes its data.** Setting `grafana = { enabled = false }` (or
  the same for Loki or Fluent Bit) and applying removes the Helm release and deletes the
  namespace, along with anything else in it, including resources Terraform did not create. The
  StorageClass reclaims volumes with `Delete`, so the volume goes too: for Grafana that means
  dashboards and settings made in the UI; for Loki on the filesystem backend, every log. A
  namespace shared with a component that stays on is kept. Read the plan first.
- **Destroy**: on S3, `terraform destroy` keeps non-empty buckets unless
  `loki.storage.force_destroy` is true. The KMS key enters its deletion window (30 days by
  default). Objects in Glacier IR or Deep Archive deleted early are billed for the rest of
  their minimum duration.

## What was verified

Run `scripts/validate.sh`. Nothing in it calls AWS or a cluster. As of this version:

| Check | Result |
|---|---|
| `terraform fmt`, `terraform validate` (root and integration), tflint | clean |
| `terraform test`: 7 suites, providers mocked | 61 runs pass |
| Rendered values through `helm template` with the pinned charts | Loki on the filesystem backend and in both modes on S3 (one with an internal NLB Service), agent in both source modes, event collector, Grafana |
| Pod Security "restricted" on every rendered Loki and Grafana pod | pass |
| kubeconform (Kubernetes 1.34 schemas) | 113 of 113 resources valid |
| checkov on the Terraform (every optional component on) | 77 passed, 0 failed, 7 skipped with reasons |
| checkov on the rendered manifests | 2,275 passed, 0 failed, 20 skipped with reasons |
| Rendered Loki config (archive tier on) through `loki -verify-config` (3.7.9) | valid, both modes |
| Rendered Fluent Bit configs through `fluent-bit --dry-run` (5.1.3) | all four valid, no unknown-key warnings; a misspelled plugin option fails |

Tests that were checked by breaking the code on purpose: the tier rule's tenant prefix, VPC
CIDRs reaching an unexposed gateway, the Pod Security level of a shared namespace, lines
sent exactly as written, `refresh_interval` rendered as seconds, and the storage backend's default.

### End-to-end on kind

`tests/e2e/run.sh` applies the real root module to a local kind cluster (Docker Desktop),
with [moto](https://github.com/getmoto/moto) standing in for AWS (S3, KMS, IAM, STS, EC2 and
the EKS cluster lookup). Only `providers.tf` is swapped in a work copy, plus two storage
resources moto cannot emulate (below). Then `run.sh check` runs 39 checks (`ONLY=coverage` runs one section):

```bash
tests/e2e/run.sh up      # kind cluster eks-logging-e2e + moto, about 1 minute
tests/e2e/run.sh apply   # terraform apply, about 5 minutes
tests/e2e/run.sh check
tests/e2e/run.sh down    # delete the cluster and moto
```

`TFVARS=e2e-filesystem.tfvars tests/e2e/run.sh apply` deploys the default filesystem storage
instead, and `check` adapts: 41 of 41 passed, with no AWS resource in the state or bucket in
moto, and all 308,440 lines in a fixed window still there after Loki's pod restarted. On that
run, turning Grafana off deleted its namespace and volume while Loki and the agents kept running,
turning it back on recreated them, and `terraform destroy` left no namespaces or volumes. The
results below are from the S3 configuration.

| Area | What it proved |
|---|---|
| Components | Loki (Monolithic), gateway, caches, Fluent Bit agent on both nodes, event collector, pod-lifecycle and Grafana all Ready from one apply |
| Gateway | TLS verified with the stack's CA; no password and a wrong password get 401; the tenant credential gets 200 |
| Evicted pods | 300 of 300 lines in Loki for each of: Eviction API with no grace period, kubelet eviction (ephemeral-storage limit), force delete, a pod that lives about a second |
| Eviction records | the kubelet's `Evicted` event with its reason; pod-lifecycle records `EvictionByEvictionAPI` and the kubelet eviction with last lines |
| NetworkPolicies | enforced by kind's CNI: a pod in another namespace and an unlabelled pod in `logging` cannot reach the gateway; a pod with the Fluent Bit label can |
| S3 layout | Loki wrote every chunk under `<tenant>/` and its index under `index/`, so the tier rule moves chunks and leaves the index in Standard |
| Grafana | the datasource health check passes with the password and CA read from mounted files |
| Every container | each container with output on either node, in all 6 namespaces (system pods included), has a stream in Loki |
| Container shapes | init container, sidecar, 50 stdout and 50 stderr lines each with the right `stream`; a JSON line with non-ASCII text byte for byte |
| Long lines | a 100 KB line arrives whole (joined from 16 KB parts); a 400 KB line is cut to 256 KB and the 50 lines after it arrive |
| Volume and rotation | 300,000 lines through at least two kubelet rotations: every line, no duplicates |
| Crash loops | 8 pods crash-looping during that burst: all 100 lines of each of the first 3 attempts (2,400) |
| Node logs | kubelet and containerd journal from both nodes |
| Agent health | 0 records dropped or abandoned (agent metrics) |

The runs found three bugs, now fixed:
- Lines of a force-deleted pod arrived with no namespace, pod or container, because the pod
  was gone from the API before the agent's metadata lookup. The agent now falls back to the
  file name.
- Lines arrived wrapped in JSON with `time` and other fields added by the kubernetes
  filter. The agent now sends only the line.
- With 2s file discovery, the first attempt of a crash-looping container was lost for up
  to half the pods: the kubelet deletes that log about 1s after it appears. Discovery is now
  every 0.5s (0 of 90 lost under a rotating burst; about 1 ms of CPU per second more). The
run also showed the VPC CNI check degrading to a plan warning, not an error, when the add-on
cannot be read.

What the e2e run cannot show, because moto is not AWS:
- **Bucket policies** are left out: moto ignores `Condition` blocks, so the TLS-only
  statements deny every request. They are covered by the storage tests only.
- **Lifecycle rules** are left out: moto drops `ObjectSizeGreaterThan` from the rule it
  returns, so the provider never sees it settle. Covered by the storage tests only.
- **IRSA**: Loki uses static keys against moto, and skips verifying moto's throwaway
  certificate.
- **kind uses kindnet, not the VPC CNI**, so VPC CNI specifics (probe handling, the
  service-port rule) are still unverified.

Not verified:

- **Nothing has been applied** to AWS or an EKS cluster. The e2e run covers Kubernetes
  behaviour on kind; AWS behaviour is covered only by mocked tests and moto.
- **Loki reading chunks from Glacier Instant Retrieval.** AWS documents millisecond GETs for
  the class, so Loki should not notice; it was not tested.
- **The S3 restore path** for archived chunks.
- **VPC CNI behaviour**: that it admits kubelet probes without a rule (an AWS re:Post article
  says so) and enforces these policies as written.
- **The AMG integration** against a real workspace and VPC connection.
- **Pod Identity with Loki** and **Bottlerocket nodes**: not tested.
- **Node logs on EKS**: the journal path (`/var/log/journal` on AL2023) and unit names were
  checked against kind's `/run/log/journal` only. Bottlerocket has no journald access this way.
- **0.5s discovery at scale**: CPU was measured with about 115 log files on a node, not at
  EKS's 110-pod limit with many containers each.
- **The aggregator and log-keeper** were not part of the e2e run (log-keeper needs an image
  built and loaded into kind).

## Cost estimate

List prices for us-east-1; check the AWS Pricing Calculator for your region before applying.
An estimate, not a bill.

**Filesystem storage (the default), 50 GB/day of raw logs:** about $8/month for the 100 GiB
gp3 volume, $1 more for Grafana's 10 GiB, and up to about $20/month in data transfer when agents
send across zones. Requests reserve about 2.1 vCPU and 5.3 GiB for Loki, its caches and the
gateway, which may need more node capacity.

**S3 storage**, 50 GB/day of raw logs (7.5 GB/day compressed):

| Item | Basis | Per month |
|---|---|---|
| EBS gp3 volumes | 3 x 50 GiB Loki at $0.08/GB (+10 GiB if Grafana is on) | about $12-13 |
| KMS key | $1 per key plus requests; bucket keys cut S3's KMS calls | about $1-2 |
| S3 storage, 90 days, tiered | see the table above | about $12 |
| S3 requests | chunk writes and query reads | about $5-20 |
| Glacier IR reads | queries older than 30 days that miss the cache, $0.03/GB | depends on use |
| Aggregator volumes (if on) | 2 x 20 GiB | about $3 |
| Internal NLB (if on) | about $16 plus capacity units | about $20 |

**Data transfer** is often the largest item: with replication factor 3 over three zones,
every ingested byte crosses zones about twice at $0.01/GB each way, roughly $60/month at
50 GB/day. Pin Loki to one zone (`loki.node_selector`) if that trade suits you.

**Cluster capacity** reserved (requests): 4.1 vCPU and 9.3 GiB for Loki, its caches and the
gateway; 0.03 vCPU and 0.1 GiB for the event collector and pod-lifecycle; 0.1 vCPU and 128 MiB
per node for the agent; 0.1 vCPU and 256 MiB more with Grafana. One m7i.2xlarge on demand is
about $290/month if you need a new node.

At 50 GB/day, expect roughly $90-110/month in AWS charges before any extra node capacity.
