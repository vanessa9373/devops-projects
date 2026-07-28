# Architecture Deep Dive — Kubernetes Microservices Deployment

For the high-level architecture, cost breakdown, and design decisions, see the
[README](../README.md). This doc covers the provisioning order, IRSA trust mechanics, and how
autoscaling/observability actually work end to end.

---

## Terraform apply order (why the `depends_on`s exist)

Terraform's graph mostly figures out ordering from resource references, but EKS has a few
dependencies that aren't expressed through attribute references alone:

```
VPC + subnets (vpc.tf)
        |
IAM cluster role (iam.tf)
        |
EKS cluster (eks.tf) ── needs a role and subnets to even start creating
        |
        ├── OIDC provider (iam.tf) ── needs the cluster's issuer URL, which
        |                              only exists once the cluster resource
        |                              is created (data "tls_certificate"
        |                              reads aws_eks_cluster.main.identity)
        |
        ├── vpc-cni, kube-proxy addons ── need a cluster, not nodes
        |
        └── EKS managed node group (eks.tf) ── needs the cluster + node IAM role
                    |
                    ├── coredns addon ── needs schedulable pods somewhere,
                    |                     so it explicitly depends_on the
                    |                     node group, not just the cluster
                    |
                    ├── metrics-server addon ── same reasoning
                    |
                    └── cloudwatch-observability addon ── needs both the
                                                             node group AND
                                                             the IRSA role
                                                             (depends on the
                                                             OIDC provider)
```

The practical effect: `terraform apply` on a from-scratch cluster does the right thing in one
pass with no "run apply twice" workaround, because every ordering constraint that Terraform
can't infer on its own is spelled out via `depends_on`.

---

## IRSA: how a pod gets AWS permissions without node-wide credentials

Without IRSA, every pod on a node inherits whatever IAM role is attached to the node's EC2
instance profile — a pod compromise means every AWS permission every workload on that node
might ever need. IRSA scopes credentials to the individual pod's service account instead:

1. `aws_iam_openid_connect_provider.eks` (iam.tf) registers the cluster's OIDC issuer with AWS
   IAM, using a TLS cert thumbprint (`data.tls_certificate.eks`) so AWS trusts tokens the
   cluster itself issues.
2. `aws_iam_role.cloudwatch_observability`'s trust policy allows
   `sts:AssumeRoleWithWebIdentity`, but only for principals presenting a token where the `sub`
   claim matches `system:serviceaccount:amazon-cloudwatch:*` — i.e., only pods running as one
   of the service accounts the `amazon-cloudwatch-observability` addon itself creates in the
   `amazon-cloudwatch` namespace. No other pod in the cluster can assume this role.
3. `aws_eks_addon.cloudwatch_observability`'s `service_account_role_arn` tells the addon to
   annotate its own service accounts with that role ARN — the EKS Pod Identity Webhook (built
   into every EKS cluster) injects short-lived AWS credentials into those pods at startup based
   on that annotation.

The result: the CloudWatch agent pods can call `cloudwatch:PutMetricData` and related APIs;
nothing else in the cluster can, even though they're all running on the same nodes.

---

## Autoscaling: from `kubectl` load to more pods

```
load hits backend pods
        |
        v
kubelet on each node reports container CPU usage
        |
        v
metrics-server (EKS addon) aggregates it, exposes via the metrics.k8s.io API
        |
        v
HorizontalPodAutoscaler (k8s/backend/hpa.yaml) polls that API every ~15s,
compares actual CPU utilization against the 60% target
        |
        v
if average utilization > 60%: HPA increases backend Deployment's replica
count (up to maxReplicas: 6); the Deployment controller schedules new pods
        |
        v
new pods pass their readinessProbe (GET /status/200) before the backend
Service starts sending them traffic
```

`scaleDown.stabilizationWindowSeconds: 120` on both HPAs means a brief dip in load doesn't
immediately scale back down — it waits 2 minutes of sustained lower usage first, avoiding a
scale-up/scale-down flap under bursty traffic.

This entire chain breaks silently (HPA shows `<unknown>` for current CPU) if the
`metrics-server` addon isn't installed or hasn't finished starting — the most common thing to
check first if `kubectl get hpa` shows no data.

---

## Observability: two separate CloudWatch paths

It's easy to conflate these — they're configured in different files and cover different layers:

| | Configured in | Covers | Where it lands |
|---|---|---|---|
| Control-plane logging | `eks.tf`, `enabled_cluster_log_types` | API server, audit, authenticator, controller-manager, scheduler | `/aws/eks/<cluster-name>/cluster` log group |
| Container Insights | `addons.tf`, `amazon-cloudwatch-observability` | Node/pod/container CPU, memory, network metrics; pod and application logs | CloudWatch Container Insights dashboards + `/aws/containerinsights/<cluster-name>/*` log groups |

Control-plane logging tells you what the Kubernetes control plane itself did (who called the
API, did the scheduler place a pod, did a controller error out). Container Insights tells you
how the workloads running on the cluster are actually behaving. Debugging "my deployment won't
roll out" starts with the first; "my pods are OOMKilled" starts with the second.

---

## Known limitations / next steps

- Frontend Service uses the in-tree AWS cloud provider for its NLB — fine for a single Service,
  but a real multi-service app with path-based routing needs the AWS Load Balancer Controller
  and Ingress resources instead, which weren't added here to keep IAM/Helm scope down.
- No `PodDisruptionBudget`s — a node drain (e.g. during a node group update) could take down
  both replicas of a Deployment simultaneously if they land on the same node.
- HPA scales on CPU only; a real service would likely also scale on custom/external metrics
  (request latency, queue depth).
- Redis is a single unscaled, unreplicated pod — acceptable for a demo cache, not for anything
  where losing the cache's contents on pod restart matters.
