#!/usr/bin/env bash
# Tear down in the right order: delete the LoadBalancer Service *first*.
# It provisions a real NLB outside terraform's state — if you `terraform
# destroy` the VPC while that NLB still exists, the subnet/VPC deletion
# hangs or fails because AWS won't delete a subnet with an active ENI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Deleting the frontend LoadBalancer Service (releases the NLB)"
kubectl -n microservices-demo delete service frontend --ignore-not-found --wait=true

echo "==> Deleting remaining app resources"
kubectl delete namespace microservices-demo --ignore-not-found --wait=true

echo "==> terraform destroy"
(cd "$PROJECT_ROOT/terraform" && terraform destroy -auto-approve)
