# Terraform — EKS cluster

Provisions the VPC, EKS control plane, managed node group, and cluster addons
(vpc-cni, kube-proxy, coredns, metrics-server, amazon-cloudwatch-observability).
See the project [README](../README.md) for the full write-up.

```bash
terraform init
terraform apply

# Point kubectl at the new cluster
$(terraform output -raw configure_kubectl)

# Then deploy the app — see ../k8s/
kubectl apply -f ../k8s/
```
