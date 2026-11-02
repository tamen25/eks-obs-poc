# EKS logging stack: Fluent Bit, Loki and Grafana

Terraform that installs a log pipeline into an existing EKS cluster: Fluent Bit on every
node, Loki with S3 storage, and Grafana with a dashboard for evicted pods. It carries over what
the eviction lab in the parent folder measured (`../FINDINGS.md`), so pods that are evicted,
drained or force-deleted keep their last log lines.

Nothing in this folder has been applied to a real AWS account or EKS cluster yet. See
[What was verified](#what-was-verified) before the first apply.

## What it deploys

```
 every node                         namespace "logging" (Pod Security: privileged)
 ┌────────────────────────────┐
 │ fluent-bit (DaemonSet)     │──┐  tails /var/log/containers (or /var/log/keep)
 │ log-keeper (optional)      │  │  hard-links new logs so deletion does not lose them
 └────────────────────────────┘  │
   fluent-bit-events (1 pod)  ───┤  Kubernetes events (Evicted, Killing, Preempted, ...)
   pod-lifecycle (1 pod)      ───┤  pod terminal states: disruption reason, last log lines
   fluent-bit-aggregator      ◄──┘  optional: agents forward here, it pushes to Loki
          │ TLS + Basic Auth
          ▼
 namespace "loki" (Pod Security: restricted)
   loki-gateway (nginx, auth, tenant mapping) ─► loki (Monolithic or Distributed)
                                                   │ IRSA or Pod Identity
                                                   ▼
                                         S3 chunks + ruler buckets (SSE-KMS)
 namespace "grafana" (Pod Security: restricted)
   grafana ─► Loki datasource (TLS, Basic Auth)  ─► CloudWatch datasource (optional, EKS audit log)
```

| Module | Creates |
|---|---|
| `modules/platform` | three namespaces with Pod Security labels, an encrypted gp3 StorageClass |
| `modules/loki-storage` | KMS key (rotating), two S3 buckets: private, TLS-only, SSE-KMS, lifecycle rules |
| `modules/workload-identity` | IAM role plus IRSA trust or a Pod Identity association |
| `modules/internal-tls` | private CA and server certificates for in-cluster TLS |
| `modules/loki` | Loki Helm release, tenant credentials, gateway TLS Secret, NetworkPolicies |
| `modules/fluent-bit` | agent and event collector Helm releases, pipeline ConfigMaps, optional aggregator StatefulSet |
| `modules/log-keeper` | DaemonSet that keeps deleted pod logs readable for a set time |
| `modules/pod-lifecycle` | Deployment that logs pod terminal states as JSON |
| `modules/grafana` | Grafana Helm release, datasources, dashboards |
| `modules/network-policies` | default-deny ingress for the agents and Grafana namespaces |

The `*/values` folders under `loki`, `fluent-bit` and `grafana` are pure modules (no
providers) that turn variables into Helm values and Fluent Bit config. The tests render them
offline.

Chart and image versions (pinned in `variables.tf`):

| Component | Chart | App |
|---|---|---|
| Loki | `grafana-community/loki` 20.0.2 | 3.7.9 |
| Fluent Bit | `fluent/fluent-bit` 0.58.3 | 5.1.3 |
| Grafana | `grafana-community/grafana` 14.2.0 | 13.3.0 |

The OSS Loki and Grafana charts moved from `grafana/helm-charts` to
`grafana-community/helm-charts` on 2026-03-16. `grafana/loki` now serves Grafana Enterprise
Logs, so do not point `loki.chart_repository` back at it.

## Before you start

The cluster needs these, and this stack does not install them:

- **EBS CSI driver** add-on, for Loki, Grafana and aggregator volumes.
- **An IAM OIDC provider** for the cluster (IRSA mode), or the **eks-pod-identity-agent**
  add-on (`aws_identity_mode = "pod_identity"`).
- **Network policy enforcement** if you turn on `network_policies`. On the VPC CNI, set
  `enableNetworkPolicy: "true"` in the add-on configuration.
- **AWS Load Balancer Controller** if you expose Loki or Grafana through an `alb` Ingress.
- **Control plane audit logging** to CloudWatch if you turn on `grafana.cloudwatch_audit`.

The identity running Terraform needs IAM, S3, KMS and EKS permissions in the account, and
cluster-admin in the cluster through an EKS access entry. Terraform gets a short-lived token
from `aws eks get-token` on every run (set `kubernetes_auth_role_arn` to assume a role for
that), so the AWS CLI must be on PATH.

Tools: Terraform >= 1.9 (tested with 1.13.3), AWS CLI v2, and for `scripts/validate.sh`:
tflint, helm, kubeconform, checkov, Python 3 with PyYAML.

## Usage

1. **Remote state.** State holds the tenant password, the Grafana admin password and the
   internal TLS private keys. Copy `backend.tf.example` to `backend.tf` and point it at an S3
   bucket with SSE-KMS, versioning and access limited to the people who run this.
2. **Settings.** Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in at least
   `cluster_name`, `aws_region` and `environment`.
3. **Plan and apply.**

   ```bash
   terraform init
   terraform plan -out tfplan
   terraform apply tfplan
   ```

4. **Log in to Grafana.** The admin password is in the `grafana/grafana-admin` Secret:

   ```bash
   kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
   kubectl -n grafana port-forward svc/grafana 3000:80
   ```

   The "Evicted pod logs" dashboard is in the Logging folder. Wire SSO through
   `grafana.ini_overrides` (for example `auth.generic_oauth`) and keep this account for
   break-glass use.

## Controlling endpoints

Every address the stack uses is a variable.

| What | Variable | Default |
|---|---|---|
| Where agents push | `fluent_bit.loki_endpoint_override` (+ `loki_endpoint_password`) | this stack's gateway, `https://loki-gateway.loki.svc.cluster.local:443` |
| Where Grafana queries | `grafana.loki_datasource_url` | the same gateway |
| Loki outside the cluster | `loki.gateway.ingress` (host, class, annotations, TLS Secret) | off |
| Grafana outside the cluster | `grafana.ingress`, `grafana.root_url` | off |
| S3 API endpoint | `loki_storage.s3_endpoint` | AWS default for the region |
| Bucket access only through VPC endpoints | `loki_storage.allowed_vpc_endpoint_ids` | not restricted |
| Image registry (pull-through cache, air gap) | `image_registry_mirror`, `fluent_bit.image.repository`, `log_keeper.image`, `pod_lifecycle.image` | public registries |

Examples:

```hcl
# Ship this cluster's logs to a central Loki instead of deploying one's own reader path.
fluent_bit = {
  loki_endpoint_override = {
    host      = "loki.logging.internal.example.com"
    port      = 443
    tenant_id = "team-payments"  # sent as X-Scope-OrgID
    username  = "team-payments"
  }
}
loki_endpoint_password = "..."  # from your secret store, for example TF_VAR_loki_endpoint_password

# Let other clusters push to this Loki through an internal ALB.
loki = {
  gateway = {
    ingress = {
      enabled = true
      host    = "loki.logging.internal.example.com"
      annotations = {
        "alb.ingress.kubernetes.io/scheme"           = "internal"
        "alb.ingress.kubernetes.io/target-type"      = "ip"
        "alb.ingress.kubernetes.io/certificate-arn"  = "arn:aws:acm:..."
        "alb.ingress.kubernetes.io/backend-protocol" = "HTTPS"  # gateway serves TLS internally
        "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
      }
    }
  }
}
```

An override endpoint is verified against the system CA bundle in the Fluent Bit image, not
the internal CA.

## Choosing features

| Feature | Variable | Use it when |
|---|---|---|
| Loki deployment mode | `loki.deployment_mode` | `Monolithic` (default) up to a few tens of GB/day; `Distributed` above that |
| Aggregator tier | `aggregator.enabled` | Loki may be slow or down for minutes, and a node dying then must not take the backlog with it. With it, a node crash cost about 0.5s of logs in the lab instead of 5-18s |
| log-keeper | `log_keeper.enabled` + `log_keeper.image` | short-lived or force-deleted pods must not lose logs, and shipper restarts mid-incident must not either. Build the image from `images/log-keeper` first |
| Pod terminal states | `pod_lifecycle.enabled` (on) | you want the eviction reason and the last lines even when the log file is gone |
| EKS audit dashboard | `grafana.cloudwatch_audit` | you need to know who drained or evicted a pod |
| NetworkPolicies | `network_policies.enabled` | the CNI enforces them |

Collection settings that came out of the lab, with their defaults:

| Setting | Default | Why |
|---|---|---|
| `fluent_bit.refresh_interval` | 2s | New-file discovery. 2s or less catches every kubelet-evicted pod (its files stay about 3s). Lines in files already tailed are read on each write regardless |
| `fluent_bit.rotate_wait` | 300s | How long a deleted pod log is still read. Fluent Bit's default of 5s lost lines when the agent was behind |
| filesystem buffering | always on | With memory-only buffering the input pauses, and a file deleted during the pause was never read (94% lost in the lab) |
| `loki.limits.max_line_size_truncate` | true | Without it, a line over 256KB is dropped and the client is told it succeeded |
| `loki.gateway.client_max_body_size` | 16M | The chart's 4M rejects larger agent batches with HTTP 413 |
| agent priority and tolerations | `system-node-critical`, tolerate all | The agent must outlive node-pressure evictions and NoExecute taints |

For workloads whose last lines matter, also set `terminationMessagePolicy:
FallbackToLogsOnError` on their containers. The pod-lifecycle watcher then ships the last 10
lines from the pod status even if the log file is gone.

## Operations

- **Rotate the tenant password**: increase `loki.credentials_revision` and apply. Loki, the
  agents and Grafana get the new value in the same apply; expect a few seconds of rejected
  pushes while pods restart, which the agents retry.
- **Certificates**: server certificates last a year and are replaced on the first apply within
  30 days of expiry (`internal_tls.early_renewal_hours`). Apply at least monthly, or move to
  cert-manager.
- **Never change `loki.schema_from`** after the first deployment. Add a new schema period
  through `loki.extra_values_yaml` instead.
- **Upgrading charts**: change the version variables, run `scripts/validate.sh`, read the
  plan. The Loki chart's major versions carry breaking changes; Grafana's
  [upgrade guide](https://grafana.com/docs/loki/latest/setup/upgrade/upgrade-to-community/)
  lists them.
- **Do not roll the agent DaemonSet during an incident.** A restart drops open handles on logs
  that are already deleted. log-keeper removes that risk.
- **Destroy**: `terraform destroy` keeps non-empty buckets unless `loki_storage.force_destroy`
  is true. The KMS key enters its deletion window (30 days by default).

## What was verified

Run `scripts/validate.sh`. Nothing in it calls AWS or a cluster. As of this commit:

| Check | Result |
|---|---|
| `terraform fmt`, `terraform validate`, tflint (terraform + AWS rulesets) | clean |
| `terraform test`: 6 suites, providers mocked | 27 runs pass |
| Rendered values through `helm template` with the pinned charts (Loki's chart enforces a strict JSON schema) | both Loki modes, agent in both source modes, event collector, Grafana render |
| Pod Security "restricted" on every rendered pod in the Loki and Grafana namespaces | pass |
| kubeconform (Kubernetes 1.34 schemas) | 93 of 93 resources valid |
| checkov on the Terraform (every optional module on) | 74 passed, 0 failed, 7 skipped with reasons |
| checkov on the rendered manifests | 1,910 passed, 0 failed, 17 skipped with reasons |
| Rendered Loki config through `loki -verify-config` (3.7.9) | valid, both modes |
| Rendered Fluent Bit configs through `fluent-bit --dry-run` (5.1.3) | all four valid; a misspelled option does fail |

Not verified:

- **Nothing has been applied** to AWS or a real cluster. The mocked tests prove the modules
  wire together and the guards work, not that AWS or Kubernetes accept every request.
- **The Fluent Bit dry runs used the Windows build** of 5.1.3; the cluster runs the Linux
  image of the same version.
- **Pod Identity with Loki**: Grafana documents IRSA. Pod Identity should work through the AWS
  SDK credential chain but was not tested.
- **Bottlerocket nodes**: the agent may need `fluent_bit.selinux_type`; not tested.
- **The eviction behaviour** (refresh_interval, rotate_wait, log-keeper, aggregator) was
  measured on kind with Docker, not EKS (`../FINDINGS.md`).

## Cost estimate

List prices for us-east-1 as I know them; check the AWS Pricing Calculator for your region
before applying. Estimate only, not a bill.

**AWS resources this stack creates**, with the defaults:

| Item | Basis | Per month |
|---|---|---|
| EBS gp3 volumes | 3 x 50 GiB Loki + 10 GiB Grafana at $0.08/GB | about $13 |
| KMS key | $1 per key plus requests; bucket keys cut S3's KMS calls to roughly one per object batch | about $1-2 |
| S3 storage | at 50 GB/day of raw logs, Loki's compression typically leaves 5-10 GB/day; 31 days kept | about $4-7 |
| S3 requests | chunk writes and query reads; depends on stream count and query use | about $5-20 |
| Aggregator volumes (if on) | 2 x 20 GiB | about $3 |

**Data transfer** is often the largest item: with replication factor 3 spread over three
zones, every ingested byte crosses zones about twice at $0.01/GB each way. At 50 GB/day that
is roughly $60/month. Pin Loki to one zone (`loki.node_selector`) if that trade suits you.

**Cluster capacity** the stack reserves (requests, defaults, summed from the rendered
manifests): 4.1 vCPU and 9.3 GiB memory for Loki, its caches and the gateway; 0.13 vCPU and
0.35 GiB for Grafana and the single-replica collectors; 0.1 vCPU and 128 MiB per node for the
agent. If that needs new
nodes, that is the biggest line: one m7i.2xlarge on demand is about $290/month.

At 50 GB/day, expect roughly $90-110/month in AWS charges before any extra node capacity.
