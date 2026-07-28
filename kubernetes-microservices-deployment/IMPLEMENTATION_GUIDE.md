# Kubernetes Microservices Deployment — Implementation Guide

A copy-paste-ready walkthrough for standing up the EKS cluster and deploying the demo app onto
it, from an empty account to a working, autoscaling, observable service.

> For architecture, IRSA mechanics, and autoscaling internals, see [README.md](README.md) and
> [docs/architecture-deep-dive.md](docs/architecture-deep-dive.md). This guide is the "how do I
> actually run this" companion.

---

## Prerequisites

```bash
aws --version              # 2.x
terraform --version        # >= 1.5
kubectl version --client   # 1.28+

aws sts get-caller-identity
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=us-east-1
```

**Expect this to take longer than the other two projects to provision** — EKS control planes
typically take 10-15 minutes to become active, and the managed node group another 3-5 minutes
on top of that.

---

## Step 1: Remote state backend

Same S3 bucket/DynamoDB table as the other projects in this repo (`vanessa-terraform-state` /
`terraform-state-lock`), different state key. Skip this if you already created it while setting
up `cicd-pipeline-automation`.

```bash
aws s3api head-bucket --bucket vanessa-terraform-state 2>&1 || \
  aws s3api create-bucket --bucket vanessa-terraform-state --region "$AWS_REGION"

aws dynamodb describe-table --table-name terraform-state-lock >/dev/null 2>&1 || \
  aws dynamodb create-table \
    --table-name terraform-state-lock \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
```

---

## Step 2: Provision the cluster

```bash
cd terraform
terraform init
terraform plan     # review: VPC, EKS cluster, node group, IAM/OIDC, 5 addons — ~35 resources
terraform apply
```

Grab a coffee — this genuinely takes 15-20 minutes. Terraform will sit on
`aws_eks_cluster.main: Still creating...` for a while; that's normal, not a hang.

```bash
terraform output cluster_name
terraform output configure_kubectl
```

---

## Step 3: Point kubectl at the new cluster

```bash
$(terraform output -raw configure_kubectl)
# Equivalent to: aws eks update-kubeconfig --region us-east-1 --name eks-microservices-dev-cluster

kubectl get nodes
# Expect 2 nodes, STATUS Ready, within a couple minutes of the node group finishing
```

If nodes show `NotReady` for more than ~5 minutes, check the `vpc-cni` addon status:

```bash
aws eks describe-addon --cluster-name "$(terraform output -raw cluster_name)" --addon-name vpc-cni --query addon.status
```

---

## Step 4: Deploy the app

```bash
cd ..   # back to kubernetes-microservices-deployment/

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/redis/
kubectl apply -f k8s/backend/
kubectl apply -f k8s/frontend/
```

(Or just run `./scripts/deploy.sh` from the start, which does Steps 2-4 in one shot and prints
the frontend URL when it's ready — the manual steps above are broken out here so you can see
what's actually happening at each stage.)

```bash
kubectl -n microservices-demo get pods -w
# Wait for all pods (redis: 1, backend: 2, frontend: 2) to reach Running/Ready
```

---

## Step 5: Get the frontend URL

```bash
kubectl -n microservices-demo get service frontend
# EXTERNAL-IP column will show <pending> for 2-4 minutes while the NLB provisions

# Once ready:
FRONTEND_URL=$(kubectl -n microservices-demo get service frontend \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$FRONTEND_URL"

curl "http://$FRONTEND_URL/"          # static page
curl "http://$FRONTEND_URL/api/get"   # proxied through nginx to the backend
```

---

## Step 6: Watch the HPA scale under load

```bash
kubectl -n microservices-demo get hpa
# TARGETS column shows current/target CPU % — starts near 0%

# In one terminal: generate load
kubectl -n microservices-demo run load-gen --rm -it --restart=Never \
  --image=busybox -- /bin/sh -c \
  "while true; do wget -q -O- http://backend/get; done"

# In another terminal: watch it scale
kubectl -n microservices-demo get hpa -w
# Expect backend's replica count to climb from 2 toward 6 as CPU% crosses 60
```

Stop the load generator (Ctrl+C, then `kubectl -n microservices-demo delete pod load-gen` if it
doesn't clean up on its own) and watch replicas scale back down after the 120s stabilization
window in `k8s/backend/hpa.yaml`.

---

## Step 7: Check Container Insights

```bash
# Confirm the addon is healthy
aws eks describe-addon --cluster-name "$(cd terraform && terraform output -raw cluster_name)" \
  --addon-name amazon-cloudwatch-observability --query addon.status
```

In the AWS Console: **CloudWatch → Container Insights → Performance monitoring**, select the
cluster (`eks-microservices-dev-cluster`) — you should see live CPU/memory graphs per pod and
per node, populated within a few minutes of the addon reporting `ACTIVE`.

Control-plane logs (separate from Container Insights — see the deep-dive doc for why) are under
**CloudWatch → Log groups → `/aws/eks/eks-microservices-dev-cluster/cluster`**.

---

## Teardown

```bash
./scripts/teardown.sh
# Deletes the frontend LoadBalancer Service first (releases the NLB), THEN
# terraform destroy — doing this out of order leaves an orphaned NLB that
# blocks VPC/subnet deletion.
```

If you ran `terraform destroy` directly without the script first and it hangs on deleting the
VPC/subnets, check for a leftover NLB (`aws elbv2 describe-load-balancers`) and delete it
manually, then re-run `terraform destroy`.
