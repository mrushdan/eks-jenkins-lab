# EKS Jenkins Lab

A disposable Continuous Integration and Continuous Delivery (CI/CD) lab for the Pluralsight AWS sandbox:
a 3-node Amazon Elastic Kubernetes Service (EKS) cluster with Application Load Balancer (ALB) ingress,
a Jenkins controller on EC2, and a pipeline that builds inside the cluster and deploys a demo app.

## Layout

| Path | Owner | Run by | State |
|---|---|---|---|
| `infra/platform/` | Platform team | You, from your laptop | Local |
| `infra/app/` | App team | Jenkins, every build | S3 (bucket created by platform) |
| `app/` | App team | Kaniko in a build pod | n/a |
| `k8s/` | App team | `kubectl apply` in a build pod | n/a |
| `Jenkinsfile` | App team | Jenkins | n/a |

## What the platform stack creates

- VPC with 3 public subnets across 3 Availability Zones, no NAT gateway
- EKS 1.35 (upgrade policy pinned to STANDARD support), access entries only
- Managed node group: 3 x t3.medium, on-demand
- Add-ons: VPC CNI, kube-proxy, CoreDNS, EKS Pod Identity Agent
- AWS Load Balancer Controller v3.4.3 via Helm, credentials through EKS Pod Identity
- Jenkins LTS controller on t3.medium, configured entirely by Configuration as Code, with the pipeline job pre-created
- `jenkins` namespace plus `jenkins-agent` service account bound to an IAM role (ECR, S3 state, EKS)
- S3 bucket for the app stack's Terraform state
- Admin password (and optional GitHub token) in SSM Parameter Store

## Pipeline stages

1. **Version**: tag = `app/VERSION` + short commit SHA, for example `1.0.0-3f9c2ab`
2. **Terraform: app stack**: ECR repository with scan on push and a lifecycle policy
3. **Build and push**: Kaniko (maintained Chainguard fork), pushes the versioned tag and `latest`
4. **ECR image scan**: waits for scan on push, fails at or above `FAIL_ON_SEVERITY` (default CRITICAL)
5. **Deploy to EKS**: renders manifests with the image tag, waits for the rollout
6. **Smoke test**: polls the ALB until it serves the new version

## Quick start (every new sandbox)

```bash
./lab.sh up          # prompts for sandbox keys, archives stale state, applies, waits for Jenkins
./lab.sh status      # account, session age, cluster, nodes, Jenkins health
./lab.sh outputs     # Jenkins URL, admin password, webhook URL
```

`lab.sh up` handles the fresh-account problem for you:

- Stores the sandbox keys in an AWS CLI profile (`pluralsight`), not in your shell
- Detects when the account ID changed and archives the previous sandbox's `terraform.tfstate` and kubeconfig entries into `.lab/archive/`
- Creates `infra/platform/terraform.tfvars` from your git remote if it does not exist
- Retries the apply once if a new cluster was not ready for the Kubernetes and Helm providers
- Waits for Jenkins, then prints the login and the new webhook URL (update it in GitHub each sandbox)

Options: `--yes` skips confirmations, `--new-creds` forces a credential prompt. `LAB_REGION=us-west-2 ./lab.sh up` switches region.

For a private repo, export the token first: `export TF_VAR_github_username=YOUR_USER TF_VAR_github_token=ghp_xxx`

**Requirements on your laptop:** bash, Terraform 1.10 or later, AWS CLI v2, kubectl, curl.

## Notes

- The Jenkins UI is open only to your current public IP (auto-detected) and to GitHub's webhook ranges. If your IP changes, run `terraform apply` again.
- No `terraform destroy` needed: the sandbox is wiped after about 4 hours.
- Helm for the app is planned as a later lesson; manifests are plain YAML on purpose.
