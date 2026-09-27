# Everything Jenkins build pods need, inside the cluster and in AWS.

resource "kubernetes_namespace_v1" "jenkins" {
  metadata {
    name = "jenkins"
  }

  depends_on = [aws_eks_node_group.this]
}

resource "kubernetes_service_account_v1" "jenkins_agent" {
  metadata {
    name      = "jenkins-agent"
    namespace = kubernetes_namespace_v1.jenkins.metadata[0].name
  }
}

# IAM role that build pods assume through EKS Pod Identity. No access keys in Jenkins.
resource "aws_iam_role" "jenkins_agent" {
  name               = "${var.project_name}-jenkins-agent"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

data "aws_iam_policy_document" "jenkins_agent" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push, pull, scan results, and Terraform management of the app repository.
  statement {
    sid       = "EcrAppRepos"
    actions   = ["ecr:*"]
    resources = ["arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}/*"]
  }

  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tf_state.arn]
  }

  statement {
    sid       = "StateBucketObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tf_state.arn}/*"]
  }

  statement {
    sid       = "DescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.this.arn]
  }
}

resource "aws_iam_role_policy" "jenkins_agent" {
  name   = "jenkins-agent"
  role   = aws_iam_role.jenkins_agent.id
  policy = data.aws_iam_policy_document.jenkins_agent.json
}

resource "aws_eks_pod_identity_association" "jenkins_agent" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = kubernetes_namespace_v1.jenkins.metadata[0].name
  service_account = kubernetes_service_account_v1.jenkins_agent.metadata[0].name
  role_arn        = aws_iam_role.jenkins_agent.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# Build pods deploy the app (namespaces, deployments, ingresses), so they get cluster admin.
# Fine for a lab. Scope this to specific namespaces in a real environment.
resource "aws_eks_access_entry" "jenkins_agent" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.jenkins_agent.arn
}

resource "aws_eks_access_policy_association" "jenkins_agent" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.jenkins_agent.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.jenkins_agent]
}
