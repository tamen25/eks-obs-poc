# Security

What the stack enforces, what the scanners flag and why some findings are accepted, and the
risks that remain. `scripts/validate.sh` re-runs every check listed here.

## Controls

### AWS

| Control | How |
|---|---|
| S3 buckets private | Public access block on all four settings; ACLs disabled (`BucketOwnerEnforced`) |
| Encryption at rest | SSE-KMS with a customer-managed key, yearly rotation; bucket keys on |
| Encryption in transit to S3 | Bucket policy denies `aws:SecureTransport = false` and TLS below 1.2 |
| Network path to S3 (optional) | `loki.storage.allowed_vpc_endpoint_ids` denies data access from outside the listed VPC endpoints |
| Least-privilege IAM | Loki: `ListBucket` on its two buckets, `Get/Put/DeleteObject` on their objects, KMS only via S3 in the region. Grafana (optional): CloudWatch Logs queries on the cluster's control plane log group |
| Role scoped to one workload | IRSA trust pins `sub` (namespace/service account) and `aud`; Pod Identity trust pins cluster ARN, namespace and service account session tags |
| Permissions boundary | `iam_permissions_boundary_arn` applies to every role |
| Access logging (optional) | `loki.storage.access_log_bucket` |
| Storage tiers | S3 lifecycle rules move chunks between classes; encryption stays SSE-KMS and the Loki role needs no extra permission |
| Tagging | `default_tags` on the provider: environment, cluster, stack, data classification |

### Kubernetes

| Control | How |
|---|---|
| Pod Security | `loki` and `grafana` namespaces enforce `restricted`. The agents' namespace (`logging`) enforces `privileged` (hostPath) and warns/audits against `restricted`. If Loki is put in the agents' namespace, it inherits `privileged` |
| Container hardening | Every container: `allowPrivilegeEscalation: false`, all capabilities dropped, read-only root filesystem, seccomp `RuntimeDefault`. Non-root everywhere except the agent and log-keeper (see below) |
| API access | Service account tokens unmounted where nothing calls the API. The agent's ClusterRole is read-only on pods and namespaces; the event collector adds events; pod-lifecycle can only list and watch pods. Loki has no ClusterRole |
| Authentication to Loki | Basic Auth at the gateway; the user decides the tenant (`X-Scope-OrgID` set by nginx), so clients cannot pick another tenant |
| Encryption in transit in the cluster | TLS 1.2+ from agents and Grafana to the gateway, and from agents to the aggregator, each server with its component's own private CA |
| Encryption to Amazon Managed Grafana | Internal NLB: TLS passes through to the gateway certificate, verified with the private CA. Internal ALB: ACM certificate at the ALB, HTTPS to the gateway behind it. The integration refuses plain-HTTP URLs |
| Secrets handling | Grafana reads the Loki password and CA from mounted files; Loki only gets a bcrypt hash; the Grafana chart's `assertNoLeakedSecrets` stays on. In Amazon Managed Grafana, password and CA go into the datasource's encrypted `secureJsonData` |
| Network segmentation (on by default) | Default-deny ingress for every component's pods; Loki reachable only through the gateway port, and only from the agents, Grafana and listed namespaces. VPC CIDRs reach the gateway and Grafana ports only when those are behind a load balancer. A plan-time check warns if the VPC CNI will not enforce the policies |
| Supply chain | Every chart and image pinned to a version; `latest` rejected by validation; registry mirror supported |
| Telemetry | Loki usage reporting and Grafana analytics off |
| Grafana | sign-up, anonymous access, gravatar, external snapshots and embedding off; secure cookies and HSTS when served over HTTPS |

## Scanner exceptions

checkov runs on the Terraform (with every optional module on) and on the rendered chart
manifests. Each exception is recorded where it applies.

Stack-wide (`.checkov.yaml`):

| Check | Reason |
|---|---|
| CKV_K8S_11 CPU limits | Deliberately unset: throttling stalls Loki and delays shipping; requests reserve CPU |
| CKV_K8S_15 imagePullPolicy Always | Images are pinned to versions, so `IfNotPresent` pulls the same image |
| CKV_K8S_43 image digests | Charts pin version tags; set digests through the image variables if your policy requires it |
| CKV2_K8S_6 pods without NetworkPolicy (chart scan) | The policies are Terraform resources that a scan of chart output cannot see |

Per resource (inline `#checkov:skip` comments in Terraform, `checkov.io/skip` annotations on
workloads):

| Where | Check | Reason |
|---|---|---|
| Fluent Bit agent | CKV_K8S_23, CKV_K8S_40 | Runs as UID 0 to read root-owned node logs; capabilities dropped, read-only root |
| Fluent Bit agent and event collector | CKV_K8S_35 | Fluent Bit reads output credentials only from environment variables |
| Fluent Bit agent (containers mode), event collector | CKV_K8S_38 | They query the Kubernetes API (pod metadata, events) |
| Loki gateway | CKV_K8S_40 | The nginx image runs as UID 101 |
| Loki caches | CKV_K8S_38 | Their ServiceAccount already has `automountServiceAccountToken: false` |
| Grafana | CKV_K8S_40, CKV_K8S_35 | Image runs as UID 472; the chart passes the break-glass admin login as env vars |
| S3 buckets | CKV_AWS_21 | Versioning is on through a separate resource and variable |
| S3 buckets | CKV_AWS_144, CKV2_AWS_62 | Cross-region replication and event notifications are out of scope (cost, no consumer) |
| pod-lifecycle | CKV_K8S_10/12/13/14 | Values come from variables checkov cannot resolve (defaults are set) |
| pod-lifecycle | CKV_K8S_11/15/43 | As stack-wide |

## Residual risks

- **An exposed gateway accepts connections from the whole VPC on port 8080.** With the VPC
  CNI, pods get VPC addresses too, so any pod can reach it once it is behind a load balancer.
  Basic Auth and TLS still apply. Narrow who reaches the load balancer with its security
  groups (AWS Load Balancer Controller annotations), or keep the gateway `ClusterIP` when
  nothing outside the cluster needs it.
- **The AMG integration needs an Admin service account token.** Create it per run with a
  short lifetime (README) and do not store it in tfvars.

- **The `logging` namespace is privileged.** The agent and log-keeper mount node paths. Keep
  anything else out of that namespace; Pod Security warns and audits against `restricted`.
- **Secrets in Terraform state**: tenant password, Grafana admin password, TLS private keys.
  The state backend must be encrypted and access-controlled.
- **One credential per tenant** serves both writing (agents) and reading (Grafana).
- **Egress is unrestricted** in the NetworkPolicies.
- **`pod-lifecycle` uses a third-party image** (`alpine/k8s`). Mirror it and pin a digest.
- **Internal certificates renew only on apply.** Apply at least every 30 days, or move to
  cert-manager.
- **The Kubernetes Secrets are only as safe as etcd.** EKS envelope encryption with KMS for
  Secrets is a cluster setting outside this stack; check it is on.
