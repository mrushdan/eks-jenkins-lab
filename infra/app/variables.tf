variable "aws_region" {
  type = string
}

variable "repository_name" {
  description = "ECR repository for the demo app."
  type        = string
  default     = "eks-jenkins-lab/demo-app"
}

variable "images_to_keep" {
  description = "Lifecycle policy keeps this many most recent images."
  type        = number
  default     = 15
}
