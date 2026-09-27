provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform-platform"
    }
  }
}

# Both Kubernetes-facing providers authenticate with short-lived tokens from
# `aws eks get-token`, using whatever AWS credentials your laptop is using.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
  }
}

# Helm provider v3 syntax: kubernetes and exec are nested objects, not blocks.
provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
    }
  }
}
