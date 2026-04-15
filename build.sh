#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# build.sh — Top-Level Golden Image Build Orchestrator
# =============================================================================
# Orchestrates building CIS-hardened and RKE2 golden images for Harvester HCI.
# By default, builds all three production images sequentially (they share the
# same Harvester cluster and cannot run in parallel).
#
# Image types:
#   cis-rocky9      CIS-hardened Rocky Linux 9
#   cis-debian13    CIS-hardened Debian 13
#   cis-ubuntu2404  CIS-hardened Ubuntu 24.04
#   rke2            RKE2 pre-baked Rocky Linux 9
#
# Usage:
#   ./build.sh                           Build all three production images
#   ./build.sh build all                 Same as above
#   ./build.sh build cis-rocky9          Build a single image
#   ./build.sh build cis-debian13        Build a single image
#   ./build.sh build rke2                Build a single image
#   ./build.sh build cis-ubuntu2404      Build experimental image
#   ./build.sh list                      Show all golden images
#   ./build.sh delete <name>             Delete a golden image
#   ./build.sh destroy                   Manual cleanup (all sub-projects)
#
# Environment variables (set by CI pipeline or .env file for local dev):
#   IMAGE_NAME_OVERRIDE    Full image name (e.g., rocky-9.7-cis-20260310)
#   PROXY_CACHE_DL_URL     Cloud image download proxy (e.g., https://dl.example.com)
#   PROXY_CACHE_YUM_URL    RPM repo proxy (e.g., https://yum.example.com)
#   PROXY_CACHE_EPEL_URL   EPEL 9 full baseurl (e.g., https://epel.example.com/epel/9/Everything/x86_64)
#   PROXY_CACHE_APT_URL    APT repo proxy (e.g., https://apt.example.com)
#
# For local development, copy .env.example to .env and fill in your values.
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

# Load .env file if present (for local development)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# Default production builds (sequential — they share the Harvester cluster)
DEFAULT_BUILDS=("cis-rocky9" "cis-debian13" "cis-ubuntu2404" "rke2")

# All known image types
declare -A IMAGE_BUILDERS=(
  ["cis-rocky9"]="cis"
  ["cis-debian13"]="cis"
  ["cis-ubuntu2404"]="cis"
  ["rke2"]="rke2"
)

# CIS distro tfvars mapping
declare -A CIS_TFVARS=(
  ["cis-rocky9"]="distros/rocky9.tfvars"
  ["cis-debian13"]="distros/debian13.tfvars"
  ["cis-ubuntu2404"]="distros/ubuntu2404.tfvars"
)

# Experimental images — warn when building
declare -A EXPERIMENTAL=(
)

# --- Helpers ---

# Resolve the sub-project build script for an image type
get_build_script() {
  local image_type="$1"
  local builder="${IMAGE_BUILDERS[$image_type]:-}"
  if [[ -z "$builder" ]]; then
    die "Unknown image type: ${image_type}"
  fi
  local script="${SCRIPT_DIR}/${builder}/build.sh"
  if [[ ! -x "$script" ]]; then
    die "Build script not found or not executable: ${script}"
  fi
  echo "$script"
}

# Format elapsed seconds as Xm Ys
format_duration() {
  local total="$1"
  local mins=$(( total / 60 ))
  local secs=$(( total % 60 ))
  echo "${mins}m ${secs}s"
}

# --- Build Command ---

cmd_build() {
  local targets=("$@")

  # Default: build all production images
  if [[ ${#targets[@]} -eq 0 ]] || [[ "${targets[0]}" == "all" ]]; then
    targets=("${DEFAULT_BUILDS[@]}")
  fi

  # Validate all targets before starting
  for target in "${targets[@]}"; do
    if [[ -z "${IMAGE_BUILDERS[$target]:-}" ]]; then
      die "Unknown image type: ${target}\n  Valid types: ${!IMAGE_BUILDERS[*]}"
    fi
    get_build_script "$target" > /dev/null
  done

  local total=${#targets[@]}
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  Harvester Golden Image Builder${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BLUE}  Building ${total} image(s): ${targets[*]}${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  local overall_start
  overall_start=$(date +%s)

  # Track results: image_type -> "OK|FAIL|SKIP duration"
  declare -A results=()
  local any_failed=0

  for i in "${!targets[@]}"; do
    local target="${targets[$i]}"
    local position=$(( i + 1 ))
    local build_start
    build_start=$(date +%s)

    echo ""
    echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${CYAN}  [${position}/${total}] Building: ${target}${NC}"
    echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
    echo ""

    # Warn for experimental images
    if [[ -n "${EXPERIMENTAL[$target]:-}" ]]; then
      log_warn "${target} is experimental and may not produce a fully working image"
    fi

    local builder="${IMAGE_BUILDERS[$target]}"
    local script
    script=$(get_build_script "$target")
    local build_rc=0

    if [[ "$builder" == "cis" ]]; then
      local tfvars="${CIS_TFVARS[$target]}"
      local tfvars_path="${SCRIPT_DIR}/cis/${tfvars}"
      if [[ -f "$tfvars_path" ]]; then
        "$script" build -f "$tfvars" || build_rc=$?
      else
        # CI mode: no tfvars file, set distro via env and rely on TF_VAR_ variables
        local distro_name="${target#cis-}"
        TF_VAR_distro="$distro_name" "$script" build || build_rc=$?
      fi
    else
      "$script" build || build_rc=$?
    fi

    local build_elapsed=$(( $(date +%s) - build_start ))
    local duration
    duration=$(format_duration "$build_elapsed")

    if [[ "$build_rc" -eq 0 ]]; then
      results[$target]="OK ${duration}"
      log_ok "${target} completed in ${duration}"
    else
      results[$target]="FAIL ${duration}"
      any_failed=1
      log_error "${target} failed after ${duration} (exit code: ${build_rc})"
      if [[ "$position" -lt "$total" ]]; then
        log_warn "Continuing with remaining builds..."
      fi
    fi
  done

  # --- Summary ---
  local overall_elapsed=$(( $(date +%s) - overall_start ))
  local overall_duration
  overall_duration=$(format_duration "$overall_elapsed")

  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  Build Summary${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""

  for target in "${targets[@]}"; do
    local result="${results[$target]}"
    local status="${result%% *}"
    local duration="${result#* }"

    if [[ "$status" == "OK" ]]; then
      echo -e "  ${GREEN}[PASS]${NC}  ${target}  (${duration})"
    else
      echo -e "  ${RED}[FAIL]${NC}  ${target}  (${duration})"
    fi
  done

  echo ""
  echo -e "  ${BOLD}Total time: ${overall_duration}${NC}"
  echo ""

  if [[ "$any_failed" -ne 0 ]]; then
    die "One or more builds failed. See output above for details."
  fi

  echo -e "${BOLD}${GREEN}All ${total} image(s) built successfully.${NC}"
  echo ""
}

# --- List Command ---

cmd_list() {
  # Delegate to both sub-scripts and combine output
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  Golden Images in Harvester${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"

  echo ""
  echo -e "${BOLD}CIS-Hardened Images:${NC}"
  echo ""
  "${SCRIPT_DIR}/cis/build.sh" list 2>/dev/null || log_warn "Could not list CIS images"

  echo ""
  echo -e "${BOLD}RKE2 Images:${NC}"
  echo ""
  "${SCRIPT_DIR}/rke2/build.sh" list 2>/dev/null || log_warn "Could not list RKE2 images"
}

# --- Delete Command ---

cmd_delete() {
  local image_name="${1:-}"
  if [[ -z "$image_name" ]]; then
    die "Usage: ./build.sh delete <image-name>\n  Run './build.sh list' to see available images."
  fi

  # Try CIS first, then RKE2 — the sub-scripts validate existence
  if "${SCRIPT_DIR}/cis/build.sh" delete "$image_name" 2>/dev/null; then
    return 0
  fi

  if "${SCRIPT_DIR}/rke2/build.sh" delete "$image_name" 2>/dev/null; then
    return 0
  fi

  die "Image '${image_name}' not found. Run './build.sh list' to see available images."
}

# --- Destroy Command ---

cmd_destroy() {
  echo ""
  log_info "Running destroy on all sub-projects..."
  echo ""

  local rc=0

  echo -e "${BOLD}CIS sub-project:${NC}"
  "${SCRIPT_DIR}/cis/build.sh" destroy -auto-approve || rc=$?

  echo ""
  echo -e "${BOLD}RKE2 sub-project:${NC}"
  "${SCRIPT_DIR}/rke2/build.sh" destroy -auto-approve || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    log_warn "One or more destroy operations had issues (see above)"
  else
    log_ok "All sub-projects cleaned up"
  fi
}

# --- Usage ---

usage() {
  cat <<EOF
Usage: $(basename "$0") [command] [args...]

Harvester Golden Image Builder — Orchestrates CIS and RKE2 image builds

Commands:
  build [target...]     Build golden images (default: all production images)
  list                  Show all golden images in Harvester
  delete <name>         Delete a golden image
  destroy               Manual cleanup of all sub-projects

Build targets:
  all                   All production images (default)
  cis-rocky9            CIS-hardened Rocky Linux 9
  cis-debian13          CIS-hardened Debian 13
  rke2                  RKE2 pre-baked Rocky Linux 9
  cis-ubuntu2404        CIS-hardened Ubuntu 24.04 (experimental)

Examples:
  $(basename "$0")                           # Build all three production images
  $(basename "$0") build all                 # Same as above
  $(basename "$0") build cis-rocky9          # Build only CIS Rocky 9
  $(basename "$0") build cis-rocky9 rke2     # Build two specific images
  $(basename "$0") build cis-ubuntu2404      # Build experimental image
  $(basename "$0") list                      # Show all golden images
  $(basename "$0") delete rocky9-cis-golden-20260309
  $(basename "$0") destroy                   # Clean up all sub-projects
EOF
}

# --- Main ---

# No args = build all
if [[ $# -eq 0 ]]; then
  cmd_build
  exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
  build)
    cmd_build "$@"
    ;;
  list)
    cmd_list
    ;;
  delete)
    cmd_delete "$@"
    ;;
  destroy)
    cmd_destroy
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    die "Unknown command: ${COMMAND}\n  Run '$(basename "$0") --help' for usage."
    ;;
esac
