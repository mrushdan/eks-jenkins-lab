output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "region" {
  value = var.aws_region
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}

output "jenkins_url" {
  value = "http://${aws_instance.jenkins.public_ip}:8080/"
}

output "jenkins_admin_password" {
  description = "terraform output -raw jenkins_admin_password"
  value       = random_password.jenkins_admin.result
  sensitive   = true
}

output "github_webhook_url" {
  description = "Paste into GitHub > Settings > Webhooks (content type application/json, push events)."
  value       = "http://${aws_instance.jenkins.public_ip}:8080/github-webhook/"
}

output "jenkins_bootstrap_log" {
  description = "Watch the controller come up without SSH."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.jenkins.id}  (then: sudo tail -f /var/log/jenkins-bootstrap.log)"
}

output "tf_state_bucket" {
  value = aws_s3_bucket.tf_state.bucket
}

output "ecr_repo_name" {
  value = var.ecr_repo_name
}

output "jenkins_allowed_cidrs" {
  value = local.my_cidrs
}
