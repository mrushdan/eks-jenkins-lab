# ---------- Who may reach Jenkins on 8080 ----------

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

# GitHub publishes the IP ranges its webhooks come from.
data "http" "github_meta" {
  url = "https://api.github.com/meta"
  request_headers = {
    Accept = "application/json"
  }
}

locals {
  my_cidrs          = length(var.allowed_cidrs) > 0 ? var.allowed_cidrs : ["${chomp(data.http.my_ip.response_body)}/32"]
  github_hook_cidrs = [for c in jsondecode(data.http.github_meta.response_body).hooks : c if !can(regex(":", c))]
  github_enabled    = var.github_token != ""
  jenkins_job_name  = "eks-jenkins-lab"
}

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins"
  description = "Jenkins controller"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_you" {
  for_each          = toset(local.my_cidrs)
  security_group_id = aws_security_group.jenkins.id
  description       = "Jenkins UI from your IP"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_github" {
  for_each          = toset(local.github_hook_cidrs)
  security_group_id = aws_security_group.jenkins.id
  description       = "GitHub webhooks"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

# Build pods on EKS connect back to the controller over WebSocket on 8080.
resource "aws_vpc_security_group_ingress_rule" "jenkins_vpc" {
  security_group_id = aws_security_group.jenkins.id
  description       = "Jenkins agents (WebSocket) from inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_egress_rule" "jenkins_all" {
  security_group_id = aws_security_group.jenkins.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# With private endpoint access on, the EKS API resolves to private IPs inside the VPC,
# so the cluster security group must allow the Jenkins controller in on 443.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_jenkins" {
  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description                  = "Kubernetes API from Jenkins controller"
  referenced_security_group_id = aws_security_group.jenkins.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# ---------- Secrets (SSM Parameter Store, never in user data) ----------

resource "random_password" "jenkins_admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "jenkins_admin_password" {
  name  = "/${var.project_name}/jenkins/admin-password"
  type  = "SecureString"
  value = random_password.jenkins_admin.result
}

resource "aws_ssm_parameter" "github_token" {
  count = local.github_enabled ? 1 : 0
  name  = "/${var.project_name}/jenkins/github-token"
  type  = "SecureString"
  value = var.github_token
}

# ---------- IAM for the controller ----------

resource "aws_iam_role" "jenkins_controller" {
  name               = "${var.project_name}-jenkins-controller"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# Session Manager instead of SSH: no key pairs, no port 22.
resource "aws_iam_role_policy_attachment" "jenkins_ssm_core" {
  role       = aws_iam_role.jenkins_controller.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "jenkins_controller" {
  statement {
    sid       = "DescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.this.arn]
  }

  statement {
    sid       = "ReadJenkinsSecrets"
    actions   = ["ssm:GetParameter"]
    resources = concat([aws_ssm_parameter.jenkins_admin_password.arn], aws_ssm_parameter.github_token[*].arn)
  }
}

resource "aws_iam_role_policy" "jenkins_controller" {
  name   = "jenkins-controller"
  role   = aws_iam_role.jenkins_controller.id
  policy = data.aws_iam_policy_document.jenkins_controller.json
}

resource "aws_iam_instance_profile" "jenkins_controller" {
  name = "${var.project_name}-jenkins-controller"
  role = aws_iam_role.jenkins_controller.name
}

# The controller only launches and manages build pods in the jenkins namespace.
resource "aws_eks_access_entry" "jenkins_controller" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.jenkins_controller.arn
}

resource "aws_eks_access_policy_association" "jenkins_controller" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.jenkins_controller.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["jenkins"]
  }

  depends_on = [aws_eks_access_entry.jenkins_controller]
}

# ---------- The instance ----------

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  jenkins_plugins = [
    "configuration-as-code",
    "kubernetes",
    "workflow-aggregator",
    "git",
    "github",
    "job-dsl",
    "credentials-binding",
    "timestamper",
    "pipeline-stage-view",
    "pipeline-graph-view",
  ]

  casc = templatefile("${path.module}/templates/casc.yaml.tftpl", {
    cluster_name          = aws_eks_cluster.this.name
    aws_region            = var.aws_region
    tf_state_bucket       = aws_s3_bucket.tf_state.bucket
    ecr_repo_name         = var.ecr_repo_name
    max_concurrent_agents = var.max_concurrent_agents
    github_repo_url       = var.github_repo_url
    github_username       = var.github_username
    github_token_enabled  = local.github_enabled
    job_name              = local.jenkins_job_name
  })
}

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.jenkins_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins_controller.name

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/jenkins-user-data.sh.tftpl", {
    aws_region           = var.aws_region
    cluster_name         = aws_eks_cluster.this.name
    admin_password_param = aws_ssm_parameter.jenkins_admin_password.name
    github_token_param   = local.github_enabled ? aws_ssm_parameter.github_token[0].name : ""
    plugins              = join("\n", local.jenkins_plugins)
    casc                 = local.casc
  })

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-jenkins" }

  # The controller writes its kubeconfig at boot, so the cluster and its access must exist first.
  depends_on = [
    aws_eks_node_group.this,
    aws_eks_access_policy_association.jenkins_controller,
    aws_iam_role_policy.jenkins_controller,
    aws_vpc_security_group_ingress_rule.cluster_from_jenkins,
    kubernetes_service_account_v1.jenkins_agent,
  ]
}
