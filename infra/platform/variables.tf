variable "aws_region" {
  description = "Pluralsight sandbox allows us-east-1 and us-west-2 only."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.aws_region)
    error_message = "The Pluralsight sandbox only allows us-east-1 or us-west-2."
  }
}

variable "project_name" {
  description = "Used for the cluster name and as a prefix for every resource."
  type        = string
  default     = "eks-jenkins-lab"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "Must be a version in EKS standard support (sandbox forbids extended support)."
  type        = string
  default     = "1.35"
}

variable "node_count" {
  description = "Number of worker nodes. One per Availability Zone at the default of 3."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 6
    error_message = "Keep node_count between 1 and 6 (sandbox caps EC2 at 9 instances total, Jenkins uses 1)."
  }
}

variable "node_instance_type" {
  description = "Sandbox allows t2, t3, t3a, t4g in micro, small, medium."
  type        = string
  default     = "t3.medium"
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "max_concurrent_agents" {
  description = "How many Jenkins build pods may run at once on the cluster."
  type        = number
  default     = 2
}

variable "lbc_version" {
  description = "AWS Load Balancer Controller app version. Must match lbc_chart_version."
  type        = string
  default     = "v3.4.3"
}

variable "lbc_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller."
  type        = string
  default     = "3.4.3"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach Jenkins on 8080. Empty means auto-detect your current public IP."
  type        = list(string)
  default     = []
}

variable "github_repo_url" {
  description = "HTTPS clone URL of the lab repository, for example https://github.com/you/eks-jenkins-lab.git"
  type        = string
}

variable "github_username" {
  description = "GitHub username that owns github_token. Only needed for a private repository."
  type        = string
  default     = ""
}

variable "github_token" {
  description = "Optional GitHub personal access token (repo read scope). Needed only for a private repository. Stored in SSM Parameter Store, never in the repo."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ecr_repo_name" {
  description = "Name of the ECR repository the app stack (run by Jenkins) will create."
  type        = string
  default     = "eks-jenkins-lab/demo-app"
}
