#!/usr/bin/env bash
# Provision the EKS cluster (if needed) and deploy the microservices demo
# onto it. Idempotent — safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "==> terraform apply"
(cd "$PROJECT_ROOT/terraform" && terraform init -input=false && terraform apply -auto-approve)

CLUSTER_NAME=$(cd "$PROJECT_ROOT/terraform" && terraform output -raw cluster_name)

echo "==> Configuring kubectl for $CLUSTER_NAME"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo "==> Waiting for the node group to be ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "==> Deploying the app"
kubectl apply -f "$PROJECT_ROOT/k8s/namespace.yaml"
kubectl apply -f "$PROJECT_ROOT/k8s/redis/"
kubectl apply -f "$PROJECT_ROOT/k8s/backend/"
kubectl apply -f "$PROJECT_ROOT/k8s/frontend/"

echo "==> Waiting for the frontend LoadBalancer to get an address (can take a few minutes)"
kubectl -n microservices-demo get service frontend --watch &
WATCH_PID=$!
for i in $(seq 1 30); do
  HOSTNAME=$(kubectl -n microservices-demo get service frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$HOSTNAME" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    echo ""
    echo "Frontend is available at: http://$HOSTNAME"
    exit 0
  fi
  sleep 10
done

kill "$WATCH_PID" 2>/dev/null || true
echo "LoadBalancer hostname not ready yet — check with:"
echo "  kubectl -n microservices-demo get service frontend"
