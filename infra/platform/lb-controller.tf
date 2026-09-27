# The controller's IAM policy is published per release. Pinning the URL to the same
# version as the chart keeps the policy and the controller in sync.
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.lbc_version}/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.project_name}-aws-load-balancer-controller"
  policy = data.http.lbc_iam_policy.response_body
}

# Shared trust policy for every role assumed through EKS Pod Identity.
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.project_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version

  # region and vpcId are set explicitly so the controller never needs the instance metadata service.
  values = [yamlencode({
    clusterName = aws_eks_cluster.this.name
    region      = var.aws_region
    vpcId       = aws_vpc.this.id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
  })]

  depends_on = [
    aws_eks_node_group.this,
    aws_eks_addon.coredns,
    aws_eks_addon.pod_identity_agent,
    aws_eks_pod_identity_association.lbc,
    aws_iam_role_policy_attachment.lbc,
  ]
}
