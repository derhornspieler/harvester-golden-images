#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# deploy.sh — Operations helper for golden image watcher on rke2-prod
# =============================================================================
# DEPLOYMENT: Managed via Fleet GitOps in harvester-rke2-svcs repo.
#   See: fleet-gitops/40-gitops/argo-workflows-manifests/manifests/
#   See: fleet-gitops/50-gitlab/runners/
# Do NOT use setup/apply/teardown for production — use Fleet.
#
# This script retains operational commands (trigger, status) and legacy
# setup commands for local testing only.
#
# Usage:
#   ./deploy.sh trigger     Manually trigger the watcher
#   ./deploy.sh status      Show CronWorkflow status
#   ./deploy.sh setup       (legacy) Store secrets in Vault + apply K8s manifests
#   ./deploy.sh apply       (legacy) Apply K8s manifests only
#   ./deploy.sh teardown    (legacy) Remove all resources
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="argo-workflows"
RUNNERS_NAMESPACE="gitlab-runners"
VAULT_PATH="services/ci/golden-image-watcher"
VAULT_KUBECONFIG_PATH="services/ci/harvester-kubeconfig"

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

die() {
  log_error "$@"
  exit 1
}

# --- Commands ---

cmd_setup() {
  log_step "Step 1: Store secrets in Vault"

  if ! command -v vault &>/dev/null; then
    die "vault CLI not found. Install it or use 'apply' if secrets are already in Vault."
  fi

  # Prompt for values
  local gitlab_user gitlab_token gitlab_repo_url
  read -rp "GitLab username (for git push): " gitlab_user
  read -rsp "GitLab project access token: " gitlab_token
  echo ""
  read -rp "GitLab repo URL (e.g., gitlab.example.com/infrastructure/harvester-golden-images.git): " gitlab_repo_url

  vault kv put "${VAULT_PATH}" \
    username="${gitlab_user}" \
    token="${gitlab_token}" \
    repo-url="${gitlab_repo_url}"

  log_ok "Secrets stored in Vault at ${VAULT_PATH}"

  log_step "Step 2: Store Harvester kubeconfig in Vault"

  local kubeconfig_path="${SCRIPT_DIR}/../kubeconfig-harvester.yaml"
  if [[ ! -f "$kubeconfig_path" ]]; then
    read -rp "Path to Harvester kubeconfig: " kubeconfig_path
  fi

  if [[ ! -f "$kubeconfig_path" ]]; then
    die "Harvester kubeconfig not found at ${kubeconfig_path}"
  fi

  vault kv put "${VAULT_KUBECONFIG_PATH}" \
    kubeconfig=@"${kubeconfig_path}"

  log_ok "Harvester kubeconfig stored in Vault at ${VAULT_KUBECONFIG_PATH}"

  cmd_apply
}

cmd_apply() {
  log_step "Step 1: Apply ExternalSecret"
  kubectl apply -f "${SCRIPT_DIR}/external-secret-gitlab-token.yaml"
  log_ok "ExternalSecret applied"

  # Wait for secret to sync
  log_info "Waiting for ExternalSecret to sync..."
  local retries=0
  while [[ $retries -lt 30 ]]; do
    local status
    status=$(kubectl get externalsecret gitlab-golden-images-token -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$status" == "True" ]]; then
      log_ok "ExternalSecret synced — K8s secret created"
      break
    fi
    sleep 2
    retries=$((retries + 1))
  done

  if [[ $retries -ge 30 ]]; then
    log_warn "ExternalSecret not yet synced. Check: kubectl get externalsecret -n ${NAMESPACE}"
  fi

  log_step "Step 2: Create watcher script ConfigMap"
  kubectl create configmap golden-image-watcher-script \
    --namespace "${NAMESPACE}" \
    --from-file=check-upstream.sh="${SCRIPT_DIR}/scripts/check-upstream.sh" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_ok "Watcher script ConfigMap created/updated"

  log_step "Step 3: Apply Harvester kubeconfig ExternalSecret (for runner)"
  kubectl apply -f "${SCRIPT_DIR}/external-secret-harvester-kubeconfig.yaml"
  log_ok "Harvester kubeconfig ExternalSecret applied"

  log_step "Step 4: Apply CronWorkflow"
  kubectl apply -f "${SCRIPT_DIR}/watcher-cronworkflow.yaml"
  log_ok "CronWorkflow applied"

  echo ""
  log_ok "Deployment complete. Run '${0} status' to verify."
}

cmd_trigger() {
  log_info "Submitting manual watcher run..."

  if command -v argo &>/dev/null; then
    argo submit --from cronwf/golden-image-watcher -n "${NAMESPACE}" --wait --log
  else
    # Fallback: create a Workflow from the CronWorkflow spec
    kubectl create job "golden-image-watcher-manual-$(date +%s)" \
      --from=cronjob/golden-image-watcher -n "${NAMESPACE}" 2>/dev/null \
      || log_warn "Manual trigger via kubectl may not work for Argo CronWorkflows. Install argo CLI."
  fi
}

cmd_status() {
  echo ""
  echo -e "${BOLD}CronWorkflow:${NC}"
  kubectl get cronworkflow golden-image-watcher -n "${NAMESPACE}" 2>/dev/null \
    || log_warn "CronWorkflow not found"

  echo ""
  echo -e "${BOLD}Recent Workflow runs:${NC}"
  kubectl get workflows -n "${NAMESPACE}" -l "workflows.argoproj.io/cron-workflow=golden-image-watcher" \
    --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -5 \
    || echo "  (none)"

  echo ""
  echo -e "${BOLD}ExternalSecret:${NC}"
  kubectl get externalsecret gitlab-golden-images-token -n "${NAMESPACE}" 2>/dev/null \
    || log_warn "ExternalSecret not found"

  echo ""
  echo -e "${BOLD}ConfigMap:${NC}"
  kubectl get configmap golden-image-watcher-script -n "${NAMESPACE}" 2>/dev/null \
    || log_warn "ConfigMap not found"
  echo ""
}

cmd_teardown() {
  log_warn "Removing all golden-image-watcher resources from ${NAMESPACE}..."

  kubectl delete cronworkflow golden-image-watcher -n "${NAMESPACE}" --ignore-not-found
  kubectl delete configmap golden-image-watcher-script -n "${NAMESPACE}" --ignore-not-found
  kubectl delete externalsecret gitlab-golden-images-token -n "${NAMESPACE}" --ignore-not-found
  kubectl delete externalsecret harvester-kubeconfig -n "${RUNNERS_NAMESPACE}" --ignore-not-found

  log_ok "Resources removed. Vault secrets were NOT deleted."
}

# --- Usage ---

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Deploy golden image watcher to rke2-prod.

Commands:
  setup       Store secrets in Vault + apply K8s manifests
  apply       Apply K8s manifests only (secrets already in Vault)
  trigger     Manually trigger the watcher
  status      Show deployment status
  teardown    Remove all resources (keeps Vault secrets)
EOF
}

# --- Main ---
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  setup)    cmd_setup ;;
  apply)    cmd_apply ;;
  trigger)  cmd_trigger ;;
  status)   cmd_status ;;
  teardown) cmd_teardown ;;
  -h|--help|help) usage ;;
  *) die "Unknown command: $1" ;;
esac
