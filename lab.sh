#!/usr/bin/env bash
#
# lab.sh: bootstrap the EKS Jenkins lab into a fresh Pluralsight AWS sandbox.
#
#   ./lab.sh up [--yes] [--new-creds]   Credentials, stale-state cleanup, terraform apply, kubeconfig, wait for Jenkins
#   ./lab.sh status                     Account, session age, cluster, nodes, Jenkins
#   ./lab.sh outputs                    Jenkins URL, admin password, webhook URL
#   ./lab.sh creds                      Only (re)enter sandbox credentials
#   ./lab.sh clean                      Archive local state and forget the current sandbox
#
# Environment overrides:
#   LAB_PROFILE  AWS CLI profile to use           (default: pluralsight)
#   LAB_REGION   us-east-1 or us-west-2           (default: us-east-1)
#
# Runs on macOS (bash 3.2), Linux, WSL, and Git Bash on Windows.

set -euo pipefail

# ---------- Settings ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$SCRIPT_DIR/infra/platform"
LAB_DIR="$SCRIPT_DIR/.lab"
ARCHIVE_DIR="$LAB_DIR/archive"
LOG_DIR="$LAB_DIR/logs"
ACCOUNT_FILE="$LAB_DIR/account-id"
SESSION_FILE="$LAB_DIR/session-start"

PROFILE="${LAB_PROFILE:-pluralsight}"
REGION="${LAB_REGION:-us-east-1}"
CLUSTER_NAME="eks-jenkins-lab"
SANDBOX_HOURS=4

# Git Bash (MSYS) rewrites arguments that look like POSIX paths before handing them
# to Windows programs such as terraform.exe and aws.exe. Nothing here needs that.
export MSYS_NO_PATHCONV=1
IS_GIT_BASH=false
case "$(uname -s)" in MINGW*|MSYS*) IS_GIT_BASH=true ;; esac

MIN_TERRAFORM="1.10.0"
MIN_AWS_CLI="2.0.0"

AUTO_APPROVE=false
FORCE_NEW_CREDS=false

# ---------- Output helpers ----------

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BLUE" "$*" "$C_OFF"; }
ok()   { printf '%s    ok:%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s  warn:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

confirm() {
  # confirm "Question" default(y|n)
  local prompt="$1" default="${2:-y}" reply
  if [[ "$AUTO_APPROVE" == true ]]; then return 0; fi
  if [[ "$default" == y ]]; then prompt="$prompt [Y/n] "; else prompt="$prompt [y/N] "; fi
  read -r -p "$prompt" reply || true
  reply="${reply:-$default}"
  [[ "$reply" == y || "$reply" == Y || "$reply" == yes ]]
}

# Returns 0 if version $1 >= version $2 (numeric, dot separated).
version_ge() {
  local -a a b
  local i x y
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for i in 0 1 2; do
    x="${a[$i]:-0}"; y="${b[$i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}

# Windows programs end lines with CRLF; drop the carriage returns.
strip_cr() { tr -d '\r'; }

# Run terraform from inside the platform directory. Using cd instead of -chdir keeps
# POSIX paths away from terraform.exe on Windows.
tf() { (cd "$PLATFORM_DIR" && terraform "$@"); }

# ---------- Preflight ----------

check_region() {
  case "$REGION" in
    us-east-1|us-west-2) ;;
    *) die "LAB_REGION=$REGION is not allowed in the Pluralsight sandbox (use us-east-1 or us-west-2)." ;;
  esac
}

check_tools() {
  step "Checking local tools"
  local missing=""
  command -v terraform >/dev/null 2>&1 || missing="$missing terraform"
  command -v aws       >/dev/null 2>&1 || missing="$missing aws"
  command -v kubectl   >/dev/null 2>&1 || missing="$missing kubectl"
  command -v curl      >/dev/null 2>&1 || missing="$missing curl"
  [[ -z "$missing" ]] || die "Missing tools:$missing"

  local tf_ver aws_ver
  tf_ver="$(terraform version | strip_cr | head -1 | sed -E 's/^Terraform v([0-9.]+).*/\1/')"
  version_ge "$tf_ver" "$MIN_TERRAFORM" || die "Terraform $tf_ver found; $MIN_TERRAFORM or later is required."
  ok "terraform $tf_ver"

  aws_ver="$(aws --version 2>&1 | strip_cr | sed -E 's#^aws-cli/([0-9.]+).*#\1#')"
  version_ge "$aws_ver" "$MIN_AWS_CLI" || die "AWS CLI $aws_ver found; v2 is required (the Kubernetes and Helm providers call 'aws eks get-token')."
  ok "aws-cli $aws_ver"

  if [[ "$IS_GIT_BASH" == true ]]; then
    ok "Git Bash on Windows detected (path conversion off, CRLF handled)"
  fi
  ok "kubectl $(kubectl version --client 2>/dev/null | strip_cr | head -1 | sed -E 's/^Client Version: //')"
}

# Environment credentials silently override the named profile, so clear them for this run.
clear_env_credentials() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]]; then
    warn "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are set in your shell. Ignoring them in favor of profile '$PROFILE'."
    warn "Run 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN' so other tools don't use stale keys."
  fi
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  export AWS_PROFILE="$PROFILE"
  export AWS_REGION="$REGION"
  export AWS_DEFAULT_REGION="$REGION"
}

current_account() {
  aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null | strip_cr || true
}

# ---------- Credentials ----------

prompt_credentials() {
  step "Enter credentials for the new Pluralsight sandbox (profile '$PROFILE')"
  local key secret token
  read -r  -p "  Access key ID: " key
  read -r -s -p "  Secret access key: " secret; echo
  read -r -s -p "  Session token (press Enter if none): " token; echo
  [[ -n "$key" && -n "$secret" ]] || die "Access key ID and secret access key are both required."

  aws configure set aws_access_key_id     "$key"    --profile "$PROFILE"
  aws configure set aws_secret_access_key "$secret" --profile "$PROFILE"
  if [[ -n "$token" ]]; then
    aws configure set aws_session_token "$token" --profile "$PROFILE"
  else
    aws configure set aws_session_token "" --profile "$PROFILE"
  fi
  aws configure set region "$REGION" --profile "$PROFILE"
  aws configure set output json --profile "$PROFILE"
}

ensure_credentials() {
  local account
  if [[ "$FORCE_NEW_CREDS" == true ]]; then
    prompt_credentials
  else
    account="$(current_account)"
    if [[ -n "$account" && "$account" != "None" ]]; then
      if ! confirm "Profile '$PROFILE' works for account $account. Use it?" y; then
        prompt_credentials
      fi
    else
      warn "Profile '$PROFILE' has no working credentials (new sandbox or expired session)."
      prompt_credentials
    fi
  fi

  step "Verifying credentials"
  ACCOUNT_ID="$(current_account)"
  [[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != "None" ]] || die "Credentials were rejected by AWS. Recopy them from Pluralsight and run './lab.sh creds'."
  ok "account $ACCOUNT_ID, region $REGION"
}

# ---------- Stale state handling ----------

has_local_state() {
  [[ -f "$PLATFORM_DIR/terraform.tfstate" || -f "$PLATFORM_DIR/terraform.tfstate.backup" ]]
}

forget_kube_entries() {
  local account="$1" region arn
  [[ -n "$account" ]] || return 0
  for region in us-east-1 us-west-2; do
    arn="arn:aws:eks:$region:$account:cluster/$CLUSTER_NAME"
    kubectl config delete-context "$arn" >/dev/null 2>&1 || true
    kubectl config delete-cluster "$arn" >/dev/null 2>&1 || true
    kubectl config delete-user    "$arn" >/dev/null 2>&1 || true
  done
}

archive_state() {
  local old_account="$1" reason="$2" dest
  dest="$ARCHIVE_DIR/$(date +%Y%m%d-%H%M%S)-${old_account:-unknown}"
  mkdir -p "$dest"
  local f moved=false
  for f in terraform.tfstate terraform.tfstate.backup .terraform.tfstate.lock.info; do
    if [[ -f "$PLATFORM_DIR/$f" ]]; then
      mv "$PLATFORM_DIR/$f" "$dest/"
      moved=true
    fi
  done
  forget_kube_entries "$old_account"
  if [[ "$moved" == true ]]; then
    ok "archived old state to ${dest#"$SCRIPT_DIR"/} ($reason)"
  else
    rmdir "$dest" 2>/dev/null || true
  fi
  # .terraform/ (provider plugins) is account-independent, so it is kept to skip re-downloads.
}

handle_account_change() {
  step "Checking for leftover state from a previous sandbox"
  mkdir -p "$LAB_DIR"
  local previous=""
  [[ -f "$ACCOUNT_FILE" ]] && previous="$(strip_cr < "$ACCOUNT_FILE")"

  if [[ "$previous" == "$ACCOUNT_ID" ]]; then
    ok "same sandbox as last run ($ACCOUNT_ID); keeping state"
    return 0
  fi

  if has_local_state; then
    if [[ -n "$previous" ]]; then
      archive_state "$previous" "account changed $previous -> $ACCOUNT_ID"
    else
      warn "Found Terraform state but no record of which account it belongs to."
      if confirm "Archive it and start clean? (Say no only if it belongs to account $ACCOUNT_ID)" y; then
        archive_state "" "unknown account"
      fi
    fi
  else
    ok "no previous state"
  fi

  echo "$ACCOUNT_ID" > "$ACCOUNT_FILE"
  date +%s > "$SESSION_FILE"
}

# ---------- tfvars ----------

ensure_tfvars() {
  step "Checking terraform.tfvars"
  local tfvars="$PLATFORM_DIR/terraform.tfvars"

  if [[ ! -f "$tfvars" ]]; then
    local remote url=""
    remote="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null | strip_cr || true)"
    if [[ "$remote" == git@github.com:* ]]; then
      url="https://github.com/${remote#git@github.com:}"
    elif [[ "$remote" == https://github.com/* ]]; then
      url="$remote"
    fi
    [[ -z "$url" || "$url" == *.git ]] || url="$url.git"

    if [[ -n "$url" ]]; then
      printf 'github_repo_url = "%s"\n' "$url" > "$tfvars"
      ok "created terraform.tfvars from git remote: $url"
    else
      die "No terraform.tfvars and no GitHub remote found. Copy infra/platform/terraform.tfvars.example to terraform.tfvars and set github_repo_url."
    fi
  fi

  if grep -q 'YOUR_GITHUB_USER' "$tfvars"; then
    die "github_repo_url in infra/platform/terraform.tfvars still has the placeholder. Set it to your repo URL."
  fi
  ok "$(grep -E '^[[:space:]]*github_repo_url' "$tfvars" | head -1 | sed -E 's/[[:space:]]+/ /g')"

  if [[ -n "${TF_VAR_github_token:-}" ]]; then
    ok "GitHub token provided via TF_VAR_github_token (private repo mode)"
  fi
}

# ---------- Terraform ----------

run_apply() {
  local log="$1" status
  local -a args=(apply -input=false -var="aws_region=$REGION")
  [[ "$AUTO_APPROVE" == true ]] && args+=(-auto-approve)

  set +e
  tf "${args[@]}" 2>&1 | tee -a "$log"
  status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

terraform_up() {
  mkdir -p "$LOG_DIR"
  local log
  log="$LOG_DIR/apply-$(date +%Y%m%d-%H%M%S).log"

  step "terraform init"
  tf init -input=false | tee -a "$log"

  step "terraform apply (about 15 to 20 minutes on a new sandbox)"
  if run_apply "$log"; then
    ok "apply complete"
    return 0
  fi

  # A brand-new cluster sometimes isn't ready when the Kubernetes and Helm providers first connect.
  if grep -qiE 'kubernetes|helm|connection refused|no such host|unauthorized|timeout' "$log"; then
    warn "Apply failed on what looks like the new-cluster provider race. Retrying once in 30 seconds."
    sleep 30
    if run_apply "$log"; then
      ok "apply complete on retry"
      return 0
    fi
  fi
  if [[ "$IS_GIT_BASH" == true && "$AUTO_APPROVE" != true ]]; then
    warn "If the Terraform approval prompt did not accept your input, rerun with: ./lab.sh up --yes"
  fi
  die "terraform apply failed. Full log: ${log#"$SCRIPT_DIR"/}"
}

tf_output() {
  tf output -raw "$1" 2>/dev/null | strip_cr || true
}

configure_kubectl() {
  step "Pointing kubectl at the cluster"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --profile "$PROFILE" >/dev/null
  ok "context arn:aws:eks:$REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME"
  kubectl get nodes -L topology.kubernetes.io/zone || warn "kubectl could not list nodes yet"
}

wait_for_jenkins() {
  local url code i
  url="$(tf_output jenkins_url)"
  [[ -n "$url" ]] || { warn "No jenkins_url output found"; return 0; }

  step "Waiting for Jenkins to finish bootstrapping (usually 3 to 5 minutes)"
  for i in $(seq 1 48); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}login" || true)"
    if [[ "$code" == 200 ]]; then
      ok "Jenkins is up"
      return 0
    fi
    printf '    attempt %s/48: HTTP %s\r' "$i" "${code:-000}"
    sleep 15
  done
  echo
  warn "Jenkins not answering after 12 minutes. Check the bootstrap log:"
  warn "$(tf_output jenkins_bootstrap_log)"
}

print_summary() {
  local url pass hook
  url="$(tf_output jenkins_url)"
  pass="$(tf_output jenkins_admin_password)"
  hook="$(tf_output github_webhook_url)"

  step "Lab ready"
  printf '    Account:          %s (%s)\n' "$ACCOUNT_ID" "$REGION"
  printf '    Jenkins:          %s\n' "${url:-n/a}"
  printf '    Login:            admin / %s\n' "${pass:-n/a}"
  printf '    GitHub webhook:   %s\n' "${hook:-n/a}"
  printf '    kubectl profile:  %s\n' "$PROFILE"
  echo
  echo "    Next: update the GitHub webhook URL (it changes every sandbox), then run the job once manually."
  echo "    In other terminals, run: export AWS_PROFILE=$PROFILE"
  if [[ "$IS_GIT_BASH" == true ]]; then
    echo "    In PowerShell instead:     \$env:AWS_PROFILE = \"$PROFILE\""
  fi
}

# ---------- Commands ----------

cmd_up() {
  check_region
  check_tools
  clear_env_credentials
  ensure_credentials
  handle_account_change
  ensure_tfvars
  terraform_up
  configure_kubectl
  wait_for_jenkins
  print_summary
}

cmd_creds() {
  check_region
  clear_env_credentials
  FORCE_NEW_CREDS=true
  ensure_credentials
}

cmd_outputs() {
  clear_env_credentials
  ACCOUNT_ID="$(strip_cr < "$ACCOUNT_FILE" 2>/dev/null || echo unknown)"
  has_local_state || die "No Terraform state yet. Run './lab.sh up'."
  print_summary
}

cmd_status() {
  clear_env_credentials
  step "Sandbox"
  local account recorded started elapsed
  account="$(current_account)"
  recorded="$(strip_cr < "$ACCOUNT_FILE" 2>/dev/null || true)"
  if [[ -n "$account" && "$account" != "None" ]]; then
    ok "credentials valid for account $account"
  else
    warn "credentials in profile '$PROFILE' are not valid (sandbox expired?)"
  fi
  [[ -n "$recorded" ]] && echo "    Local state belongs to: $recorded"
  if [[ -n "$account" && -n "$recorded" && "$account" != "$recorded" ]]; then
    warn "Profile account differs from local state. './lab.sh up' will archive the old state."
  fi
  if [[ -f "$SESSION_FILE" ]]; then
    started="$(cat "$SESSION_FILE")"
    elapsed=$(( ( $(date +%s) - started ) / 60 ))
    echo "    Session age: ${elapsed} min (sandbox lasts about $((SANDBOX_HOURS * 60)) min)"
    if (( elapsed > SANDBOX_HOURS * 60 - 30 )); then
      warn "Sandbox is near or past its time limit."
    fi
  fi

  [[ -n "$account" && "$account" != "None" ]] || return 0

  step "Cluster"
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$PROFILE" \
    --query 'cluster.{status:status,version:version,endpoint:endpoint}' --output table 2>/dev/null \
    || warn "cluster $CLUSTER_NAME not found in $REGION"
  kubectl get nodes 2>/dev/null || true

  step "Jenkins"
  local url code
  url="$(tf_output jenkins_url)"
  if [[ -n "$url" ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}login" || true)"
    echo "    $url (HTTP ${code:-000})"
  else
    echo "    no Jenkins output in state"
  fi
}

cmd_clean() {
  local recorded
  recorded="$(strip_cr < "$ACCOUNT_FILE" 2>/dev/null || true)"
  if ! has_local_state && [[ -z "$recorded" ]]; then
    ok "nothing to clean"
    return 0
  fi
  confirm "Archive local Terraform state and forget sandbox ${recorded:-unknown}? (AWS resources are not touched)" n || exit 0
  archive_state "$recorded" "manual clean"
  rm -f "$ACCOUNT_FILE" "$SESSION_FILE"
  ok "local lab state cleared"
}

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- Main ----------

main() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)    AUTO_APPROVE=true ;;
      --new-creds) FORCE_NEW_CREDS=true ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done

  case "$cmd" in
    up)      cmd_up ;;
    status)  cmd_status ;;
    outputs) cmd_outputs ;;
    creds)   cmd_creds ;;
    clean)   cmd_clean ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
