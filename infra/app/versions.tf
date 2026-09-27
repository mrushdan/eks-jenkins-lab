terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial backend config. Jenkins supplies bucket and region at init time:
  #   terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION"
  # use_lockfile gives S3-native state locking (no DynamoDB table needed).
  backend "s3" {
    key          = "app/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "eks-jenkins-lab"
      ManagedBy = "terraform-app"
    }
  }
}
