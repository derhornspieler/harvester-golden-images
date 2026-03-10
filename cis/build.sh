#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# build.sh — Multi-Distro CIS-Hardened Golden Image Build Orchestrator
# =============================================================================
# Creates a pre-baked cloud image with CIS hardening using virt-customize +
# OpenSCAP inside a temporary Harvester utility VM.
#
# Supported distros: rocky9, debian13, ubuntu2404
#
# Usage:
#   ./build.sh build                    Build using terraform.tfvars
#   ./build.sh build -f rocky9.tfvars   Build using specific tfvars
#   ./build.sh list                     Show existing golden images
#   ./build.sh delete <name>            Delete an old golden image
#   ./build.sh destroy                  Manual cleanup if build fails
# =============================================================================

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

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARVESTER_KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig-harvester.yaml}"
KUBECTL="kubectl --kubeconfig=${HARVESTER_KUBECONFIG}"
IMAGE_DATE=$(date +%Y%m%d)
CHECK_POD_NAME="golden-build-check"
_BUILD_VM_NAMESPACE=""
TFVARS_FILE=""

# --- Parse global flags ---
parse_flags() {
  TFVARS_FILE=""
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--var-file)
        TFVARS_FILE="$2"
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done
  set -- "${args[@]+"${args[@]}"}"
  echo "${args[@]+"${args[@]}"}"
}

# --- Helper Functions ---

_tf_var_file_arg() {
  if [[ -n "$TFVARS_FILE" ]]; then
    echo "-var-file=${TFVARS_FILE}"
  fi
}

check_prerequisites() {
  local missing=()
  for cmd in kubectl terraform jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
  log_ok "Prerequisites found: kubectl, terraform, jq"
}

ensure_kubeconfig() {
  if [[ -f "$HARVESTER_KUBECONFIG" ]]; then
    log_ok "Harvester kubeconfig found: ${HARVESTER_KUBECONFIG}"
    return 0
  fi
  die "Harvester kubeconfig not found at ${HARVESTER_KUBECONFIG}"
}

check_connectivity() {
  if ! $KUBECTL cluster-info &>/dev/null; then
    die "Cannot connect to Harvester cluster via ${HARVESTER_KUBECONFIG}"
  fi
  log_ok "Harvester cluster is reachable"
}

_get_tfvar() {
  local file="${TFVARS_FILE:-terraform.tfvars}"
  # Resolve relative paths against SCRIPT_DIR
  if [[ "$file" != /* ]]; then
    file="${SCRIPT_DIR}/${file}"
  fi
  awk -F'"' "/^${1}[[:space:]]/ {print \$2}" "$file" 2>/dev/null || echo ""
}

get_image_name() {
  # CI pipeline sets IMAGE_NAME_OVERRIDE for version-aware naming
  if [[ -n "${IMAGE_NAME_OVERRIDE:-}" ]]; then
    echo "$IMAGE_NAME_OVERRIDE"
    return
  fi
  local prefix
  prefix=$(_get_tfvar image_name_prefix)
  if [[ -z "$prefix" ]]; then
    local distro
    distro=$(_get_tfvar distro)
    [[ -z "$distro" ]] && distro="rocky9"
    prefix="${distro}-cis-golden"
  fi
  echo "${prefix}-${IMAGE_DATE}"
}

get_vm_namespace() {
  local ns
  ns=$(_get_tfvar vm_namespace)
  # Fall back to TF_VAR_ env var (used in CI)
  [[ -z "$ns" ]] && ns="${TF_VAR_vm_namespace:-}"
  [[ -z "$ns" ]] && die "vm_namespace not set in tfvars or TF_VAR_vm_namespace"
  echo "$ns"
}

deploy_check_pod() {
  local ns="$1"
  $KUBECTL delete pod "$CHECK_POD_NAME" -n "$ns" --ignore-not-found 2>/dev/null || true
  $KUBECTL run "$CHECK_POD_NAME" -n "$ns" --restart=Never \
    --image=curlimages/curl:8.12.0 -- sleep 3600 2>/dev/null
  $KUBECTL wait --for=condition=ready "pod/${CHECK_POD_NAME}" -n "$ns" \
    --timeout=120s 2>/dev/null || die "Check pod did not become ready"
  log_ok "Check pod deployed on Harvester"
}

check_vm_ready() {
  local ns="$1"
  local vm_ip="$2"
  $KUBECTL exec -n "$ns" "$CHECK_POD_NAME" -- \
    curl -sf --max-time 5 "http://${vm_ip}:8080/ready" &>/dev/null
}

cleanup_check_pod() {
  local ns="$1"
  $KUBECTL delete pod "$CHECK_POD_NAME" -n "$ns" --ignore-not-found 2>/dev/null || true
}

# --- Build Command ---

cmd_build() {
  local start_time
  start_time=$(date +%s)

  local distro
  distro=$(_get_tfvar distro)
  [[ -z "$distro" ]] && distro="rocky9"

  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  CIS-Hardened Golden Image Build — ${distro}${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  check_prerequisites
  ensure_kubeconfig
  check_connectivity

  local image_name
  image_name=$(get_image_name)
  _BUILD_VM_NAMESPACE=$(get_vm_namespace)
  local vm_namespace="$_BUILD_VM_NAMESPACE"

  if $KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" -n "${vm_namespace}" &>/dev/null; then
    die "Image '${image_name}' already exists. Use './build.sh delete ${image_name}' first."
  fi

  trap 'cleanup_check_pod "${_BUILD_VM_NAMESPACE}" 2>/dev/null || true' EXIT

  # -----------------------------------------------------------------------
  # Step 1/6: Terraform Apply
  # -----------------------------------------------------------------------
  log_step "Step 1/6: Creating base image + utility VM for ${distro}..."
  cd "$SCRIPT_DIR"

  if ! $KUBECTL get namespace terraform-state &>/dev/null; then
    log_info "Creating terraform-state namespace on Harvester..."
    $KUBECTL create namespace terraform-state
    log_ok "terraform-state namespace created"
  fi

  terraform init -reconfigure -input=false -backend-config="config_path=${HARVESTER_KUBECONFIG}"

  # Clean up orphaned builder resources if terraform state is empty
  local state_count
  state_count=$(terraform state list 2>/dev/null | wc -l || echo "0")
  if [[ "$state_count" -eq 0 ]]; then
    local prefix
    prefix=$(_get_tfvar image_name_prefix)
    [[ -z "$prefix" ]] && prefix="${distro}-cis-golden"
    local stale=0
    if $KUBECTL get virtualmachineimages.harvesterhci.io "golden-builder-${distro}-base" -n "${vm_namespace}" &>/dev/null; then
      log_warn "Cleaning up orphaned builder image..."
      $KUBECTL delete virtualmachineimages.harvesterhci.io "golden-builder-${distro}-base" -n "${vm_namespace}" --wait=false
      stale=1
    fi
    if $KUBECTL get secret "${prefix}-builder-cloudinit" -n "${vm_namespace}" &>/dev/null; then
      log_warn "Cleaning up orphaned builder secret..."
      $KUBECTL delete secret "${prefix}-builder-cloudinit" -n "${vm_namespace}"
      stale=1
    fi
    if $KUBECTL get virtualmachines.kubevirt.io "${prefix}-builder" -n "${vm_namespace}" &>/dev/null; then
      log_warn "Cleaning up orphaned builder VM..."
      $KUBECTL delete virtualmachines.kubevirt.io "${prefix}-builder" -n "${vm_namespace}" --wait=false
      stale=1
    fi
    if [[ "$stale" -eq 1 ]]; then
      log_info "Waiting for orphaned resources to be removed..."
      sleep 10
    fi
  fi

  local tf_var_file_arg
  tf_var_file_arg=$(_tf_var_file_arg)
  local tf_override_arg=""
  if [[ -n "${IMAGE_NAME_OVERRIDE:-}" ]]; then
    tf_override_arg="-var=image_name_override=${IMAGE_NAME_OVERRIDE}"
  fi
  # shellcheck disable=SC2086
  terraform apply -auto-approve -lock-timeout=600s ${tf_var_file_arg} ${tf_override_arg}

  local vm_ip
  vm_ip=$(terraform output -raw utility_vm_ip 2>/dev/null || echo "")
  if [[ -z "$vm_ip" ]]; then
    die "Could not get utility VM IP from Terraform output"
  fi
  log_ok "Utility VM created at ${vm_ip}"

  # -----------------------------------------------------------------------
  # Step 2/6: Wait for HTTP ready
  # -----------------------------------------------------------------------
  log_step "Step 2/6: Waiting for ${distro} golden image build + CIS hardening..."
  log_info "Deploying check pod on Harvester..."
  deploy_check_pod "$vm_namespace"

  local timeout=3600 interval=15 elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    if check_vm_ready "$vm_namespace" "$vm_ip"; then
      log_ok "Golden image build complete"
      break
    fi
    if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]]; then
      log_info "  Still building... (${elapsed}s / ${timeout}s)"
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  cleanup_check_pod "$vm_namespace"

  if [[ $elapsed -ge $timeout ]]; then
    log_error "Timeout waiting for golden image build (${timeout}s)"
    log_error "Debug: ssh rocky@${vm_ip} 'cat /var/log/build-golden.log'"
    die "Build timed out. Run './build.sh destroy' to clean up."
  fi

  # -----------------------------------------------------------------------
  # Step 3/6: Download CIS compliance report
  # -----------------------------------------------------------------------
  log_step "Step 3/6: Downloading CIS compliance report..."
  deploy_check_pod "$vm_namespace"

  local report_dir="${SCRIPT_DIR}/reports"
  mkdir -p "$report_dir"
  if $KUBECTL exec -n "$vm_namespace" "$CHECK_POD_NAME" -- \
    curl -sf --max-time 10 "http://${vm_ip}:8080/cis-report.html" > "${report_dir}/${distro}-cis-report-${IMAGE_DATE}.html" 2>/dev/null; then
    log_ok "CIS report saved: reports/${distro}-cis-report-${IMAGE_DATE}.html"
  else
    log_warn "Could not download CIS report (non-fatal)"
    rm -f "${report_dir}/${distro}-cis-report-${IMAGE_DATE}.html"
  fi

  cleanup_check_pod "$vm_namespace"

  # -----------------------------------------------------------------------
  # Step 4/6: Import golden image into Harvester
  # -----------------------------------------------------------------------
  log_step "Step 4/6: Importing golden image into Harvester..."

  $KUBECTL apply -f - <<VMIMAGE
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: ${image_name}
  namespace: ${vm_namespace}
spec:
  displayName: "${image_name}"
  sourceType: download
  url: "http://${vm_ip}:8080/golden.qcow2"
  storageClassParameters:
    migratable: "true"
    numberOfReplicas: "3"
    staleReplicaTimeout: "30"
VMIMAGE

  log_ok "VirtualMachineImage CRD applied: ${image_name}"

  # -----------------------------------------------------------------------
  # Step 5/6: Wait for image import
  # -----------------------------------------------------------------------
  log_step "Step 5/6: Waiting for Harvester to import image..."
  local import_timeout=600 import_elapsed=0

  while [[ $import_elapsed -lt $import_timeout ]]; do
    local progress
    progress=$($KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" \
      -n "${vm_namespace}" -o jsonpath='{.status.progress}' 2>/dev/null || echo "0")

    local conditions
    conditions=$($KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" \
      -n "${vm_namespace}" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "")

    if echo "$conditions" | jq -e '.[] | select(.type=="Imported" and .status=="True")' &>/dev/null; then
      log_ok "Image import complete: ${image_name}"
      break
    fi

    log_info "  Import progress: ${progress}% (${import_elapsed}s / ${import_timeout}s)"
    sleep 15
    import_elapsed=$((import_elapsed + 15))
  done

  if [[ $import_elapsed -ge $import_timeout ]]; then
    log_warn "Image import may still be in progress"
    log_info "Check: kubectl get virtualmachineimages ${image_name} -n ${vm_namespace}"
  fi

  # -----------------------------------------------------------------------
  # Step 6/6: Cleanup
  # -----------------------------------------------------------------------
  log_step "Step 6/6: Cleaning up utility VM..."
  cd "$SCRIPT_DIR"
  # shellcheck disable=SC2086
  terraform destroy -auto-approve -lock-timeout=600s ${tf_var_file_arg} ${tf_override_arg}
  log_ok "Utility VM and base image cleaned up"

  # --- Summary ---
  local elapsed_total=$(( $(date +%s) - start_time ))
  local mins=$(( elapsed_total / 60 ))
  local secs=$(( elapsed_total % 60 ))

  echo ""
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${BOLD}${GREEN}  CIS-Hardened Golden Image Build Complete${NC}"
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${GREEN}  Distro:    ${distro}${NC}"
  echo -e "${GREEN}  Image:     ${image_name}${NC}"
  echo -e "${GREEN}  Namespace: ${vm_namespace}${NC}"
  echo -e "${GREEN}  Time:      ${mins}m ${secs}s${NC}"
  echo ""
  echo -e "To use this image, reference it by name:"
  echo -e "  golden_image_name = \"${image_name}\""
  echo ""
}

# --- List Command ---

cmd_list() {
  ensure_kubeconfig
  check_connectivity

  local vm_namespace
  vm_namespace=$(get_vm_namespace)

  echo ""
  echo -e "${BOLD}Golden images in namespace '${vm_namespace}':${NC}"
  echo ""

  $KUBECTL get virtualmachineimages.harvesterhci.io -n "${vm_namespace}" \
    --no-headers -o custom-columns=\
'NAME:.metadata.name,DISPLAY:.spec.displayName,SIZE:.status.size,PROGRESS:.status.progress,AGE:.metadata.creationTimestamp' \
    2>/dev/null | grep -E "(rocky9|debian13|ubuntu2404)-cis-golden" || echo "  (no golden images found)"

  echo ""
}

# --- Delete Command ---

cmd_delete() {
  local image_name="${1:-}"
  if [[ -z "$image_name" ]]; then
    die "Usage: ./build.sh delete <image-name>\n  Run './build.sh list' to see available images."
  fi

  ensure_kubeconfig
  check_connectivity

  local vm_namespace
  vm_namespace=$(get_vm_namespace)

  if ! $KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" -n "${vm_namespace}" &>/dev/null; then
    die "Image '${image_name}' not found in namespace '${vm_namespace}'"
  fi

  log_info "Deleting golden image: ${image_name}..."
  $KUBECTL delete virtualmachineimages.harvesterhci.io "${image_name}" -n "${vm_namespace}"
  log_ok "Image '${image_name}' deleted"
}

# --- Destroy Command ---

cmd_destroy() {
  log_info "Running terraform destroy for manual cleanup..."
  ensure_kubeconfig

  cd "$SCRIPT_DIR"
  terraform init -reconfigure -input=false -backend-config="config_path=${HARVESTER_KUBECONFIG}"

  local tf_var_file_arg
  tf_var_file_arg=$(_tf_var_file_arg)
  terraform destroy ${tf_var_file_arg} "$@"
  log_ok "Cleanup complete"
}

# --- Main ---

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options] [args...]

Multi-Distro CIS-Hardened Golden Image Build System
Supports: rocky9, debian13, ubuntu2404

Options:
  -f, --var-file <file>    Terraform .tfvars file (default: terraform.tfvars)

Commands:
  build              Full lifecycle: create -> wait -> import -> cleanup
  list               Show existing golden images in Harvester
  delete <name>      Delete an old golden image
  destroy            Manual cleanup if build fails mid-way

Examples:
  $(basename "$0") build                          # Uses terraform.tfvars
  $(basename "$0") build -f distros/debian13.tfvars
  $(basename "$0") list
  $(basename "$0") delete rocky9-cis-golden-20260308
  $(basename "$0") destroy -auto-approve
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

# Parse flags from all args
ALL_ARGS=("$@")
COMMAND="${ALL_ARGS[0]}"
REST_ARGS=("${ALL_ARGS[@]:1}")

# Extract -f flag from remaining args
FILTERED_ARGS=()
i=0
while [[ $i -lt ${#REST_ARGS[@]} ]]; do
  case "${REST_ARGS[$i]}" in
    -f|--var-file)
      TFVARS_FILE="${REST_ARGS[$((i+1))]}"
      i=$((i + 2))
      ;;
    *)
      FILTERED_ARGS+=("${REST_ARGS[$i]}")
      i=$((i + 1))
      ;;
  esac
done

case "$COMMAND" in
  build)
    cmd_build
    ;;
  list)
    cmd_list
    ;;
  delete)
    cmd_delete "${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}"
    ;;
  destroy)
    cmd_destroy "${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    die "Unknown command: ${COMMAND}\n  Run '$(basename "$0") --help' for usage."
    ;;
esac
