# Core networking addons — required for pods to get IPs and DNS to resolve
# at all. Installed via terraform, not manually, so a fresh cluster is
# usable immediately after `terraform apply` with no follow-up kubectl steps.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_cluster.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_cluster.main]
}

# CoreDNS needs schedulable nodes to actually run — wait for the node group.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
}

# Powers the HorizontalPodAutoscalers in k8s/backend and k8s/frontend — HPA
# reads CPU/memory from the metrics API, which metrics-server provides.
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
}

# Container Insights: cluster/node/pod metrics + log collection into
# CloudWatch, with zero daemonset YAML to hand-maintain — this is the
# resume's "CloudWatch container insights and logging" bullet for the
# workload side (as opposed to eks.tf's control-plane logging).
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "amazon-cloudwatch-observability"
  service_account_role_arn    = aws_iam_role.cloudwatch_observability.arn
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.cloudwatch_observability,
  ]
}
