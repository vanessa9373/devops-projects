# Kubernetes Microservices Deployment — AWS EKS + Terraform

> **Architect:** Vanessa Awo · AWS Solutions Architect Associate
> **Stack:** Amazon EKS · Kubernetes · Terraform · Application Auto Scaling (HPA) · CloudWatch Container Insights
> **Status:** IaC-defined ✅ | Multi-service app ✅ | HPA ✅ | Container Insights ✅

---

## Problem Statement

A team needs to run several loosely-coupled services together — a frontend, an API, a cache —
without hand-building a Kubernetes cluster, hand-wiring pod-to-cluster IAM permissions, or
losing visibility into cluster/pod health once it's running.

**Goal:** stand up a production-shaped EKS cluster from Terraform alone, deploy a multi-service
app onto it that scales itself under load, and get cluster/workload observability without
maintaining a single hand-written DaemonSet.

---

## Architecture

```
                              Terraform (terraform/)
                                      |
        +-----------------------------+-----------------------------+
        |                             |                             |
   VPC (2 AZ)                  EKS control plane              EKS managed
   public + private            (API, audit, sched          node group
   subnets, 1 NAT GW           logs -> CloudWatch)          (private subnets)
        |                             |                             |
        +----------------+------------+------------+----------------+
                          |                         |
                    addons.tf installs:       IRSA (OIDC) grants
              vpc-cni, kube-proxy, coredns,   amazon-cloudwatch-observability
              metrics-server,                  pods CloudWatchAgentServerPolicy
              amazon-cloudwatch-observability   (least-privilege, pod-scoped)
                          |
                          v
        ┌─────────────────────────────────────────────────┐
        │            microservices-demo namespace           │
        │                                                    │
        │  Internet --> NLB --> frontend (nginx, 2-6 pods)   │
        │                          |  HPA: cpu > 60%          │
        │                          v                          │
        │                    backend (go-httpbin, 2-6 pods)   │
        │                          |  HPA: cpu > 60%          │
        │                          v                          │
        │                     redis (cache, 1 pod)             │
        └─────────────────────────────────────────────────┘
                          |
                          v
              CloudWatch: Container Insights metrics,
              pod/node logs, control-plane logs
```

`frontend` is nginx serving a static page and reverse-proxying `/api/` to the `backend`
Service by its cluster-internal DNS name (`backend.microservices-demo.svc.cluster.local`) —
a real service-to-service call, not just two Deployments coexisting in a namespace.

---

## Design Decisions

### Why EKS-managed addons via Terraform (not a Helm chart per component, not manual kubectl)?
- `aws_eks_addon` resources (terraform/addons.tf) mean `terraform apply` alone produces a
  cluster that's actually usable — no post-apply "now go run these five `kubectl`/`helm`
  commands" steps that inevitably drift from what's documented.
- AWS manages the addon's own upgrade/patch lifecycle, which is one less thing to own.

### Why the `amazon-cloudwatch-observability` addon (not a hand-rolled Fluent Bit DaemonSet)?
- It's the AWS-supported path to Container Insights and covers cluster, node, pod, and
  container-level metrics plus log collection in one addon — versus maintaining a DaemonSet
  YAML, a ConfigMap for Fluent Bit config, and an IAM role by hand.
- Scoped by IRSA (`iam.tf`) to only the `amazon-cloudwatch:*` service accounts the addon
  itself creates — not a blanket node-wide IAM role that every pod on the node could reach.

### Why the EKS API-based access mode (not the `aws-auth` ConfigMap)?
- `access_config { authentication_mode = "API" }` (eks.tf) manages cluster access as IAM/EKS
  API resources (`aws_eks_access_entry`) instead of a hand-edited ConfigMap that's easy to
  misconfigure and hard to audit changes to.

### Why a single NAT gateway (not one per AZ)?
- This is a demo/portfolio cluster — one NAT gateway is ~$33/month cheaper than two and the
  trade-off (all private-subnet egress depends on one AZ) is explicitly not worth paying for
  here. A real production cluster should use one NAT gateway per AZ.

### Why redis with no service actually reading/writing to it?
- It's here to make this an honest 3-tier topology (frontend / API / cache) — the standard
  shape "multi-service containerized application" usually means — while keeping the API
  implementation swappable (go-httpbin is a stand-in; see below). Wiring real cache reads/
  writes is the natural next step if this app grows real business logic.

### Why go-httpbin and nginx (not custom app code) for the services?
- This project is about cluster/orchestration mechanics — deployments, services, HPA,
  observability — not application code, which is already demonstrated in
  [`../cicd-pipeline-automation`](../cicd-pipeline-automation). Using well-known, minimal
  public images keeps the focus there.

---

## Local Development / Deploy

```bash
# Requires: AWS credentials, terraform, aws CLI, kubectl

./scripts/deploy.sh
# -> terraform apply, configures kubectl, applies k8s/, prints the frontend URL

kubectl -n microservices-demo get pods
kubectl -n microservices-demo get hpa
kubectl -n microservices-demo get service frontend
```

### Watching autoscaling happen
```bash
# Generate load against the backend to trigger the HPA
kubectl -n microservices-demo run load-gen --rm -it --restart=Never \
  --image=busybox -- /bin/sh -c \
  "while true; do wget -q -O- http://backend/get; done"

# In another terminal
kubectl -n microservices-demo get hpa -w
```

### Tear down
```bash
./scripts/teardown.sh
# Deletes the LoadBalancer Service first (releases the NLB), then terraform destroy
```

---

## Cost Analysis (us-east-1, always-on)

| Resource | Usage | Monthly Cost |
|---|---|---|
| EKS control plane | 1 cluster | $73.00 |
| EC2 (node group) | 2 × t3.medium, 24/7 | ~$60.00 |
| NAT Gateway | 1 gateway + light data | ~$33.00 |
| Network Load Balancer | 1 NLB + light traffic | ~$16.50 |
| CloudWatch (Container Insights + control plane logs) | ~2 GB/month | ~$1.50 |
| **Total** | | **~$184/month** |

> Biggest cost levers for demo use: scale the node group to 0 (`node_desired_size = 0`,
> `node_min_size = 0`) between demos, or tear down entirely with `scripts/teardown.sh` — the
> EKS control plane's flat $73/month runs regardless of whether anything is deployed on it.

---

## Project Structure

```
kubernetes-microservices-deployment/
├── terraform/
│   ├── provider.tf         # backend, provider, locals
│   ├── vpc.tf               # VPC, subnets (EKS-tagged), NAT, routing
│   ├── iam.tf                # cluster/node roles, OIDC provider, IRSA
│   ├── eks.tf                 # cluster, node group, control-plane logging
│   ├── addons.tf               # vpc-cni, coredns, metrics-server, cloudwatch-observability
│   └── outputs.tf
├── k8s/
│   ├── namespace.yaml
│   ├── redis/                  # cache tier — Deployment + Service
│   ├── backend/                # API tier — Deployment + Service + HPA
│   └── frontend/                # web tier — ConfigMap + Deployment + Service (NLB) + HPA
├── scripts/
│   ├── deploy.sh                 # terraform apply -> configure kubectl -> kubectl apply
│   └── teardown.sh               # delete LB Service -> terraform destroy (correct order)
├── .github/workflows/
│   └── terraform-ci.yml            # terraform fmt/validate + kubeconform on manifest changes
└── docs/
    └── architecture-deep-dive.md
```

---

## Skills Demonstrated

- **IaC:** Terraform-provisioned EKS cluster, VPC, IAM/IRSA, and cluster addons — fully
  repeatable, no manual post-apply steps
- **Container orchestration:** Kubernetes Deployments, Services (ClusterIP + LoadBalancer),
  ConfigMaps, ClusterIP-to-ClusterIP service calls
- **Availability & scaling:** HorizontalPodAutoscaler on CPU utilization, `PodDisruptionBudget`-
  ready rolling deployments, multi-AZ node placement
- **Observability:** CloudWatch Container Insights (cluster/node/pod metrics + logs) and
  EKS control-plane logging, both IaC-managed
- **Security:** IRSA (pod-scoped IAM via OIDC, no node-wide credentials), private subnets for
  worker nodes, EKS API-based access control
- **CI:** automated `terraform fmt`/`validate` and Kubernetes manifest schema validation
  (kubeconform) on every change

---

*Built by Vanessa Awo | [LinkedIn](https://www.linkedin.com/in/vanessaaw/) | [Portfolio](https://jenellavan.com/)*
