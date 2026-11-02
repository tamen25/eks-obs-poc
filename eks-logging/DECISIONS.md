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
    CloudWatch; AWS endpoints have no stable CIDRs to pin egress to. The VPC CNI also
    requires service port = container port for egress rules to services, which the charts
    would need to respect everywhere.
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
    network policy, AWS Load Balancer Controller). They are shared with other workloads. A
    plan-time check warns when the vpc-cni add-on would not enforce the NetworkPolicies.
20. **Grafana runs one replica with a volume.** More replicas need an external database; the
    variables enforce that.

## Second version (this folder, `eks-logging/`)

The first version is kept unchanged in `../terraform/`.

21. **Loki, Fluent Bit and Grafana are self-contained component modules, each with an
    `enabled` switch, in one root and one state.** Separate states per component would need
    the tenant password and CA passed between states (remote state or a secret store) and an
    apply order. One root keeps that wiring inside Terraform; each module still creates all of
    its own resources (buckets, IAM, certificates, NetworkPolicies) so another root can call it.
22. **Grafana is off by default.** Amazon Managed Grafana is the UI in this environment.
23. **The Amazon Managed Grafana datasource lives in a separate root,
    `integrations/amazon-managed-grafana`.** It needs a workspace token and the grafana
    provider; the main stack has no reason to hold either. The token is a short-lived
    variable rather than created in the same run, because a provider configured from a value
    only known after apply cannot plan.
24. **Loki and Fluent Bit get separate namespaces by default; sharing one is supported.** The
    agents need Pod Security `privileged`. In a shared namespace Loki's pods lose `restricted`
    enforcement (they still comply; the namespace warns and audits).
25. **Only chunks are tiered, selected by the tenant prefix.** The TSDB index, delete requests
    and the ruler bucket stay in S3 Standard: every query reads the index, and the objects are
    small. One rule per tenant; the stack has one tenant.
26. **Warm tier is Glacier Instant Retrieval (or Standard-IA); Glacier Flexible Retrieval and
    Deep Archive are only allowed as an archive tier past Loki's query window.** Loki reads
    chunks with plain GETs and cannot restore objects. With the archive tier on,
    `max_query_lookback` ends a day before the archive transition and delete requests become
    `filter-only`, since rewriting an archived chunk would fail.
27. **Chunks under 1 MiB are never tiered.** A transition costs $0.02 per 1,000 objects for
    Glacier IR; for small chunks that outweighs the storage saved. S3's own default floor is
    128 KB; this one is higher and configurable.
28. **Default retention raised from 31 to 90 days.** With 31 days, chunks would spend one day
    warm and pay the 90-day Glacier IR minimum. 90 days is the shortest default where tiering
    saves anything. It stores about three times more data than the first version's default.
29. **The plan-time cost check warns below 45 warm days (Glacier IR), not below the 90-day
    minimum.** Billed for 90 days, Glacier IR is still cheaper than Standard past about 45 days
    of use at us-east-1 prices with 1 MiB chunks. A warning, not an error: prices vary.
30. **NetworkPolicies on by default and generated.** Terraform knows every component's namespace
    and pod labels, so the rules need no input. Each policy selects one component's pods, so it
    works in shared namespaces. VPC CIDRs (read from AWS) are admitted only to the gateway and
    Grafana ports, and only when those sit behind a load balancer. No node CIDRs: the VPC CNI
    admits kubelet probes on its own, and with the VPC CNI node subnets also hold pod IPs.
31. **Service ports equal container ports** (gateway 8080, Grafana 3000, aggregator 24224). The
    VPC CNI network policy documentation requires it; it also makes the URL the same with TLS
    on or off.
32. **One CA per component.** The Loki module signs the gateway certificate, the Fluent Bit
    module signs the aggregator's. The agents get a bundle of both. A component no longer
    needs another one's CA key.
33. **The agent flushes for 30s on SIGTERM** (`grace`, termination grace period 60s), up from
    Fluent Bit's 5s, so a drain or spot reclaim does not cut the last flush short.

34. **The agent takes namespace, pod and container from the log file name when the API has no
    metadata.** The kind e2e run showed a force-deleted pod's lines arriving with no labels:
    the pod was gone before the kubernetes filter's lookup. The API still wins when it
    answers; only the pod UID is missing for such lines.
35. **End-to-end tests run on kind with moto for AWS, swapping only `providers.tf`.** That
    applies the real root module. Bucket policies and lifecycle rules are left out of the
    e2e run because moto ignores policy conditions and drops a lifecycle filter field; both
    stay covered by the storage module's tests.
36. **The agent sends each container line exactly as written.** The kind run showed lines
    arriving as JSON wrapped with `time` and other fields the kubernetes filter adds. A
    `record_modifier` allowlist now keeps only `log`, `stream` and the label keys, and the Loki
    output removes those, so only the line is left. Values tests assert the allowlist.
37. **Node logs are collected by default** (`fluent_bit.node_logs`): the kubelet and container
    runtime journal units and kernel messages, as `job=node` streams with one `unit` label.
    These are the logs to read when a pod never starts or a node is under pressure, and no
    container log file exists for them. The journal path defaults to `/var/log/journal`
    (EKS AL2023, already mounted). It gets its own read-only hostPath mount only when it
    sits outside `/var/log`.
38. **Two tail settings were tried and rejected.** `inotify_watcher false` (stat polling) cut
    lost crash-loop attempts in a short stress run but not in the full e2e run, so it fixed
    nothing measurable. `db.compare_filename true` made it worse: Fluent Bit compares the
    stored symlink name with the resolved `0.log` path, which never match on Kubernetes,
    so after a restart the agent re-read every file from the start and Loki rejected about
    65,000 old lines.
39. **New log files are discovered every 0.5s, down from 2s.** A crash-looping container's
    first attempt keeps its log for only about 1s: the kubelet keeps the newest dead
    container's log and the first restart is immediate. With 2s scans the kind run lost that
    attempt for 4 of 8 pods; with 0.5s, 0 of 8 and then 0 of 90 under a rotating burst. The
    agent used 4 ms of CPU per second against 3 ms at 2s, with about 115 log files on the
    node. Fluent Bit reads the digits after the point as nanoseconds, so the module writes
    0.5 as `0.500000000`; written as `0.5` it scanned every 5ns and used a whole core.
40. **Loki stores logs on one volume by default; S3 is opt-in.** Asked for Fluent Bit, Loki and
    Grafana first, without S3. Before this the module always created buckets, a KMS key and an
    IAM role, so it needed a switch, not a value. `loki.storage.backend` defaults to
    `filesystem`, which reverses the production-minded default on purpose and is a deviation
    from the S3 design: one replica (the chart refuses more without object storage), so Loki
    is down during a restart and a lost volume loses the logs. Replicas, retention and volume
    size default per backend, because 90 days on 50 GiB would fill at 50 GB/day and stop
    ingestion. Set the backend back to `s3` once the first deployment works.
