# metrics-server feeds the Kubernetes Metrics API: `kubectl top`, Horizontal Pod Autoscalers,
# and resource graphs in UIs such as Headlamp. Installed with Helm, like the Load Balancer Controller.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version

  values = [yamlencode({
    replicas = 1
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
    }
  })]

  depends_on = [
    aws_eks_node_group.this,
    aws_eks_addon.coredns,
  ]
}
