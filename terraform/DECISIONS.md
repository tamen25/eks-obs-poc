# Decisions

One line per decision, then why. Newest last.

1. **Loki and Grafana charts from `grafana-community/helm-charts`.** The OSS charts moved there
   on 2026-03-16; `grafana/loki` now targets Grafana Enterprise Logs and stops at Loki 3.6.
2. **Loki `Monolithic` by default, `Distributed` as the option, no `SimpleScalable`.**
   SimpleScalable is deprecated and goes away in Loki 4. Monolithic with S3 scales
   horizontally and keeps operations simple for up to a few tens of GB/day.
3. **IRSA by default, Pod Identity optional.** Grafana's EKS guide documents IRSA. Pod Identity
   should work through the AWS SDK credential chain but no source confirms it for Loki and it
   was not tested.
4. **One tenant per cluster, one credential shared by the agents and Grafana.** The nginx
   gateway maps the Basic Auth user to `X-Scope-OrgID`, so the user name must equal the tenant
   ID and a tenant cannot have separate read and write users. The Envoy gateway can, but the
   chart marks it experimental.
5. **Secrets in Terraform state, encrypted remote backend required.** The tenant password, the
   Grafana admin password and the internal TLS keys live in state. Write-only attributes
   (`set_wo`, `data_wo`) were considered: the password is consumed by three releases that must
   agree on one stable value, and an ephemeral value regenerated per run cannot guarantee
   that. Loki itself only receives the bcrypt hash.
6. **Internal TLS from a Terraform-managed CA rather than cert-manager.** It removes a cluster
   dependency. Cost: keys in state, and renewal needs an apply within 30 days of expiry.
7. **Fluent Bit pipeline in our own ConfigMap (YAML format) via `existingConfigMap`.** The
   chart's config values are classic-format strings. Our ConfigMap is rendered from typed
   variables, tested, and dry-run against the real binary. The chart's `checksum/config`
   annotation does not see it, so pods carry `checksum/pipeline-config` instead.
8. **Labels: cluster, namespace, container, job. Pod name, pod UID, node and stream are
   structured metadata.** One stream per pod would multiply Loki's index; structured metadata
   stays queryable. The pod UID tells apart StatefulSet pods that reuse a name.
9. **No CPU limits anywhere.** CFS throttling stalls Loki and delays log shipping long before a
   node runs out of CPU. CPU requests reserve capacity; memory has limits.
10. **Loki's rules sidecar is off.** It needs a ClusterRole that can read every Secret in the
    cluster. Rules can live in the ruler bucket.
11. **No Kubernetes API tokens where nothing calls the API**: Loki, the caches, Grafana, and the
    agent in keep mode. IRSA and Pod Identity inject their own token volume.
12. **The aggregator is a plain StatefulSet.** The Fluent Bit chart renders only DaemonSets and
    Deployments, and the aggregator needs one volume per replica.
13. **log-keeper ships off by default and needs an image you build** (`images/log-keeper`).
    The lab version installed packages at container start; that has no place in production.
14. **NetworkPolicies restrict ingress only.** Loki needs S3, STS and DNS, Grafana needs
    CloudWatch; AWS endpoints have no stable CIDRs to pin egress to.
15. **EKS audit events come from CloudWatch through a Grafana datasource.** EKS writes the
    audit log to CloudWatch, not to a file a node agent can tail, and the cluster's logging
    settings are outside this stack.
16. **Loki canary and Helm test pods are off.** The test pod uses a `latest` image; the canary
    needs its own tenant credentials.
17. **S3 versioning on, noncurrent versions expire after 7 days, plus a retention backstop**
    30 days past Loki's retention. Versioning protects against accidental deletes; the expiry
    keeps it from doubling storage, since Loki deletes chunks on its own schedule.
18. **Chunk cache 2 GiB instead of the chart's 8 GiB.** Sized for the default 3-replica
    Monolithic install; raise it with query load.
19. **Cluster add-ons are prerequisites, not managed here** (EBS CSI, Pod Identity agent, VPC CNI
    network policy, AWS Load Balancer Controller). They are shared with other workloads.
20. **Grafana runs one replica with a volume.** More replicas need an external database; the
    variables enforce that.
