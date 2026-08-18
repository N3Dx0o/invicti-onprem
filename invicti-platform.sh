#!/usr/bin/env bash
#===============================================================================
#  invicti-platform.sh — Invicti Platform on-premises lifecycle manager
#===============================================================================
#  Installs, upgrades, backs up, restores and removes the Invicti Platform
#  on-premises edition on a single-node k3s cluster or any existing Kubernetes
#  cluster, following the official Helm documentation:
#      https://docs.invicti.com/ip/category/invicti-platform-on-premises
#
#  COMMANDS
#    install        Preflight, install k3s + Helm 3 if needed, deploy the chart
#    check          Run every preflight check, change nothing
#    status         Health and diagnostics for an existing deployment
#    upgrade        helm upgrade to the latest (or a pinned) chart version
#    reconfigure    Re-render values.yaml from flags and apply it
#    backup         Consistent backup: values, secrets, PVC data, chart version
#    restore        Restore a backup produced by this script
#    uninstall      Remove the release; optionally purge data and cluster scope
#    logs           Collect a support bundle for Invicti Support
#    version        Print script, chart, Helm, k3s and Kubernetes versions
#
#  QUICK START
#    sudo ./invicti-platform.sh install \
#         --email you@example.com --license XXXX-XXXX --host invicti.example.com
#
#  NON-INTERACTIVE
#    INVICTI_EMAIL=... INVICTI_LICENSE_KEY=... PLATFORM_HOST=... \
#      ./invicti-platform.sh install --yes
#
#  WHY THIS EXISTS (hard-won notes)
#    * Helm 4 releases after 4.1.1 are unsupported by the chart. Helm 4 applies
#      resources server-side and fights KEDA for ownership of ScaledJob resource
#      fields, which kills the deploy. This script pins Helm 3.
#    * KEDA CRDs, ClusterRoles and webhooks are CLUSTER-scoped. `helm uninstall`
#      plus `kubectl delete namespace` leaves them behind, so the next install
#      fails with ownership metadata conflicts. `uninstall --purge` removes them.
#    * values-resources-recommended.yaml is sized for a high-availability
#      multi-node cluster. On one node most pods stay Pending. This script picks
#      a profile that fits the node and can fall back automatically.
#    * Ubuntu's guided LVM install leaves most of the disk unallocated, which
#      caps node ephemeral-storage and makes pods unschedulable even though df
#      reports free space. This script offers to reclaim it.
#===============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="3.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${SCRIPT_NAME}"

#------------------------------------------------------------------ defaults
# Anything here can be overridden by an environment variable of the same name
# or by the matching command-line flag.

NAMESPACE="${NAMESPACE:-invicti}"
RELEASE="${RELEASE:-invicti-platform}"
REGISTRY="${REGISTRY:-platform-registry.invicti.com}"
CHART_REPO="${CHART_REPO:-oci://platform-registry.invicti.com/invicti-platform-helm-charts/onpremises}"
CHART_VERSION="${CHART_VERSION:-}"          # empty = latest
PLATFORM_HOST="${PLATFORM_HOST:-invicti.local}"

INVICTI_EMAIL="${INVICTI_EMAIL:-}"
INVICTI_LICENSE_KEY="${INVICTI_LICENSE_KEY:-}"

HELM_VERSION="${HELM_VERSION:-v3.16.4}"     # chart supports Helm 3.8+
HELM_TIMEOUT="${HELM_TIMEOUT:-30m}"
WAIT_MINUTES="${WAIT_MINUTES:-30}"

# Documented per-worker-node minimums, plus practical single-node targets.
MIN_CPU="${MIN_CPU:-6}"
MIN_MEM_GI="${MIN_MEM_GI:-12}"
WANT_MEM_GI="${WANT_MEM_GI:-20}"
MIN_DISK_GI="${MIN_DISK_GI:-50}"
WANT_DISK_GI="${WANT_DISK_GI:-150}"

INSTALL_K3S="${INSTALL_K3S:-auto}"          # auto | yes | no
EXPAND_DISK="${EXPAND_DISK:-ask}"           # ask | yes | no
AUTO_FALLBACK="${AUTO_FALLBACK:-true}"
RESOURCE_PROFILE="${RESOURCE_PROFILE:-}"
SKIP_UPGRADE="${SKIP_UPGRADE:-true}"        # apt full-upgrade off by default
ASSUME_YES="${ASSUME_YES:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
NO_COLOR="${NO_COLOR:-false}"

# Optional feature configuration
SMTP_HOST="${SMTP_HOST:-}"; SMTP_PORT="${SMTP_PORT:-25}"
SMTP_MAIL="${SMTP_MAIL:-}"; SMTP_DISPLAYNAME="${SMTP_DISPLAYNAME:-Invicti Security}"
SMTP_USERNAME="${SMTP_USERNAME:-}"; SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_SECURITY="${SMTP_SECURITY:-ssl}"; SMTP_ENGINE="${SMTP_ENGINE:-smtp}"
TLS_CERT="${TLS_CERT:-}"; TLS_KEY="${TLS_KEY:-}"
DB_HOST="${DB_HOST:-}"; DB_PORT="${DB_PORT:-5432}"; DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"; DB_SSL="${DB_SSL:-false}"; DB_CERT="${DB_CERT:-}"
PROXY_HTTP="${PROXY_HTTP:-}"; PROXY_HTTPS="${PROXY_HTTPS:-}"
PROXY_NOPROXY="${PROXY_NOPROXY:-.svc.cluster.local,svc.cluster.local,localhost,127.0.0.1}"
JIRA_CLIENT_ID="${JIRA_CLIENT_ID:-}"; JIRA_CLIENT_SECRET="${JIRA_CLIENT_SECRET:-}"
KEDA_EXISTING="${KEDA_EXISTING:-false}"
SERVICE_TYPE="${SERVICE_TYPE:-}"            # LoadBalancer | NodePort | ClusterIP
NODE_PORT="${NODE_PORT:-30443}"
EXTRA_VALUES="${EXTRA_VALUES:-}"
OPENSHIFT="${OPENSHIFT:-false}"
REGISTRY_ADDRESS="${REGISTRY_ADDRESS:-}"     # pull images from your own registry
REGISTRY_PATH="${REGISTRY_PATH:-infrastructure}"
REGISTRY_PROXY_URL="${REGISTRY_PROXY_URL:-}"
TWO_PHASE="${TWO_PHASE:-false}"              # split cluster-scoped vs namespaced
SCANNER_MIN_REPLICAS="${SCANNER_MIN_REPLICAS:-auto}"   # KEDA warm DAST scanners

# Uninstall scope
PURGE_DATA="${PURGE_DATA:-false}"           # PVCs + namespace
PURGE_CLUSTER="${PURGE_CLUSTER:-false}"     # CRDs, ClusterRoles, webhooks
PURGE_K3S="${PURGE_K3S:-false}"             # remove k3s entirely

BACKUP_FILE="${BACKUP_FILE:-}"
RESTORE_FILE="${RESTORE_FILE:-}"
INCLUDE_PVC="${INCLUDE_PVC:-true}"

COMMAND=""
WARNINGS=0
FAILURES=0

# Host memory in GiB. Defined up front because several commands (upgrade,
# reconfigure, restore) size things from it without running the full preflight.
MEM_GI="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
CHART_LOCAL=""
CHART_VERSION_ACTUAL=""
P_NONE=""
VALUE_ARGS=()

#------------------------------------------------------------------ identity
# Run as a normal user (the script escalates per-command) or under sudo. Either
# way artefacts end up owned by the human, not root.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="${HOME:-/root}"
fi
WORKDIR="${WORKDIR:-$TARGET_HOME/invicti-onprem}"
BACKUP_DIR="${BACKUP_DIR:-$TARGET_HOME/invicti-backups}"
LOG_DIR="${LOG_DIR:-$TARGET_HOME/invicti-logs}"
VALUES_FILE="$WORKDIR/values.yaml"
STATE_FILE="$WORKDIR/.invicti-state"

#------------------------------------------------------------------ output
if [[ -t 1 && "$NO_COLOR" != "true" ]]; then
  C_HEAD=$'\033[1;35m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m';  C_DIM=$'\033[2m';   C_B=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_B=""; C_OFF=""
fi

log()   { printf '\n%s==> %s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '    %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; WARNINGS=$((WARNINGS+1)); }
bad()   { printf '    %s[fail]%s %s\n' "$C_ERR" "$C_OFF" "$*"; FAILURES=$((FAILURES+1)); }
hint()  { printf '%s           %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
die()   { printf '\n%s[x] %s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }

on_err() {
  local line=$1 code=$2
  printf '\n%s[x] Failed at line %s (exit %s)%s\n' "$C_ERR" "$line" "$code" "$C_OFF" >&2
  [[ -n "${LOGFILE:-}" ]] && printf '    Log: %s\n' "$LOGFILE" >&2
  printf '    This script is idempotent — fix the cause and run it again.\n' >&2
  printf '    Diagnostics: %s status\n' "$SCRIPT_NAME" >&2
}
trap 'on_err "$LINENO" "$?"' ERR

confirm() {
  local prompt="$1"
  [[ "$ASSUME_YES" == "true" ]] && return 0
  local reply
  read -rp "    ${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_OFF" "$*"
    return 0
  fi
  "$@"
}

#------------------------------------------------------------------ sudo
# Cache credentials up front and keep them warm; a chart deploy can outlive the
# default 15-minute sudo timeout and we must not stall behind a hidden prompt.
SUDO=""
SUDO_KEEPALIVE_PID=""
need_root() {
  # --dry-run changes nothing, so never escalate for it.
  if [[ "$DRY_RUN" == "true" ]]; then SUDO="sudo"; return 0; fi
  if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; return 0; fi
  command -v sudo >/dev/null || die "This command needs root and sudo is not installed."
  SUDO="sudo"
  if ! sudo -n true 2>/dev/null; then
    if [[ -n "${SUDO_ASKPASS:-}" ]]; then
      # Non-interactive path for automation: SUDO_ASKPASS=/path/to/helper
      sudo -A -v || die "sudo authentication failed via SUDO_ASKPASS."
    elif [[ -t 0 ]]; then
      info "Root privileges are required. You may be prompted for your password."
      sudo -v || die "sudo authentication failed."
    else
      printf '\n%s[x] Root privileges are required but no terminal is available to prompt.%s\n' "$C_ERR" "$C_OFF" >&2
      printf '    Choose one of:\n' >&2
      printf '      * run the whole script as root:  sudo %s %s ...\n' "$SCRIPT_NAME" "$COMMAND" >&2
      printf '      * export SUDO_ASKPASS=/path/to/askpass-helper\n' >&2
      printf '      * grant this user passwordless sudo\n' >&2
      exit 1
    fi
  fi
  if [[ -z "$SUDO_KEEPALIVE_PID" ]]; then
    ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
  fi
}

start_log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOGFILE="${LOGFILE:-$LOG_DIR/invicti-${COMMAND}-$(date +%Y%m%d-%H%M%S).log}"
  # Tee everything, but strip colour from the file copy.
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' > "$LOGFILE")) 2>&1
}

banner() {
  printf '%s%s%s  v%s   command: %s\n' "$C_B" "Invicti Platform on-premises" "$C_OFF" "$SCRIPT_VERSION" "${COMMAND}"
  [[ -n "${LOGFILE:-}" ]] && printf '%slog: %s%s\n' "$C_DIM" "$LOGFILE" "$C_OFF"
}

#===============================================================================
#  Kubernetes / Helm helpers
#===============================================================================

setup_kubeconfig() {
  # Prefer an existing working kubeconfig (someone may be targeting a remote
  # cluster); fall back to the k3s one.
  if [[ -n "${KUBECONFIG:-}" ]] && kubectl version >/dev/null 2>&1; then return 0; fi
  if [[ -r "$TARGET_HOME/.kube/config" ]]; then
    export KUBECONFIG="$TARGET_HOME/.kube/config"
    kubectl version >/dev/null 2>&1 && return 0
  fi
  if [[ -r /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    kubectl version >/dev/null 2>&1 && return 0
  fi
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    need_root
    export KUBECONFIG="$TARGET_HOME/.kube/config"
    install_kubeconfig_for_user
    kubectl version >/dev/null 2>&1 && return 0
  fi
  return 1
}

install_kubeconfig_for_user() {
  need_root
  $SUDO mkdir -p "$TARGET_HOME/.kube"
  $SUDO cp /etc/rancher/k3s/k3s.yaml "$TARGET_HOME/.kube/config"
  $SUDO chown -R "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$TARGET_HOME/.kube"
  $SUDO chmod 600 "$TARGET_HOME/.kube/config"
  export KUBECONFIG="$TARGET_HOME/.kube/config"
  if ! grep -qs 'KUBECONFIG' "$TARGET_HOME/.bashrc" 2>/dev/null; then
    printf 'export KUBECONFIG=$HOME/.kube/config\n' | $SUDO tee -a "$TARGET_HOME/.bashrc" >/dev/null
  fi
}

require_cluster() {
  setup_kubeconfig || die "No reachable Kubernetes cluster. Run '$SCRIPT_NAME install' first, or set KUBECONFIG."
  kubectl version >/dev/null 2>&1 || die "kubectl cannot reach the cluster (KUBECONFIG=${KUBECONFIG:-unset})."
}

release_exists() { helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; }
ns_exists()      { kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; }

helm_major() { helm version --short 2>/dev/null | grep -oE 'v[0-9]+' | head -1 | tr -d 'v'; }

# Pods that are neither Running-and-ready nor Completed.
not_ready_pods() {
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '
    $3 == "Completed" || $3 == "Succeeded" { next }
    { split($2, r, "/"); if ($3 != "Running" || r[1] != r[2]) print }'
}

sched_failures() {
  kubectl get events -n "$NAMESPACE" --field-selector reason=FailedScheduling \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null \
    | grep -Eio 'insufficient (cpu|memory|ephemeral-storage)' | sort -u || true
}

# 0 = everything ready, 1 = unschedulable, 2 = timed out
settle() {
  local deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
  local grace=$(( $(date +%s) + 240 ))
  local pending total badcount fails
  while (( $(date +%s) < deadline )); do
    pending="$(not_ready_pods)"
    if [[ -z "$pending" ]]; then echo; return 0; fi
    total="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    badcount="$(printf '%s\n' "$pending" | grep -c . || true)"
    printf '\r    %s/%s pods ready, %s still starting ...      ' \
      "$(( total - badcount ))" "$total" "$badcount"
    if (( $(date +%s) > grace )); then
      fails="$(sched_failures)"
      if [[ -n "$fails" ]]; then
        echo
        # A single-node rolling update often looks like a shortage but is really
        # a deadlock; try to release it once before giving up.
        if [[ "${UNWEDGED:-0}" == "0" ]]; then
          UNWEDGED=1
          prune_unschedulable_scanners
          unwedge_rollouts
          grace=$(( $(date +%s) + 180 ))
          continue
        fi
        warn "Pods cannot be scheduled. Reported shortages: $(echo "$fails" | paste -sd', ' -)"
        return 1
      fi
    fi
    sleep 15
  done
  echo
  return 2
}

#===============================================================================
#  Preflight
#===============================================================================

TRUSTLIST_HOSTS=(
  "https://platform-registry.invicti.com/v2/"
  "https://registry.invicti.com/v2/"
  "https://registry-1.docker.io/v2/"
  "https://activation.invicti.com"
  "https://sca.invicti.com"
  "https://sdds.invicti.com"
  "https://jwtsigner.invicti.com"
  "https://discovery-service.invicti.com"
  "https://static-platform.invicti.com"
  "https://sb.bxss.me"
)

disk_free_gi() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'; }
disk_size_gi() { df -BG --output=size  / 2>/dev/null | tail -1 | tr -dc '0-9'; }

preflight() {
  log "Preflight: host"

  [[ "$(uname -s)" == "Linux" ]] || die "Linux only. The vendor does not support macOS for on-premises installs."
  [[ "$(uname -m)" == "x86_64" ]] || warn "Architecture $(uname -m) is untested; x86_64 is expected."
  if grep -qi microsoft /proc/version 2>/dev/null; then
    warn "Running under WSL. The vendor ships a dedicated Windows installer for that path."
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}   kernel $(uname -r)"
    [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] \
      || warn "Not Debian/Ubuntu. Package installation steps may need adjusting."
  fi

  # --- CPU
  local cpus; cpus="$(nproc)"
  if (( cpus >= MIN_CPU )); then ok "CPU cores: ${cpus} (documented minimum ${MIN_CPU})"
  else bad "CPU cores: ${cpus}; the documented minimum per worker node is ${MIN_CPU}."; fi

  # --- Memory
  MEM_GI="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
  if   (( MEM_GI >= WANT_MEM_GI )); then ok "Memory: ${MEM_GI} GB"
  elif (( MEM_GI >= MIN_MEM_GI  )); then
    warn "Memory: ${MEM_GI} GB meets the ${MIN_MEM_GI} GB documented minimum, but that assumes a multi-node cluster."
    hint "On a single node the platform plus k3s wants roughly ${WANT_MEM_GI} GB or pods stay Pending."
  else bad "Memory: ${MEM_GI} GB is below the documented ${MIN_MEM_GI} GB minimum."; fi

  # --- Disk, and offer to reclaim unallocated LVM space
  info "Root filesystem: $(disk_size_gi) GB total, $(disk_free_gi) GB free"
  maybe_expand_disk

  local disk; disk="$(disk_free_gi)"
  if   (( disk >= WANT_DISK_GI )); then ok "Free disk: ${disk} GB"
  elif (( disk >= MIN_DISK_GI  )); then
    warn "Free disk: ${disk} GB meets the ${MIN_DISK_GI} GB minimum but is tight once images and scan data land."
    hint "SeaweedFS alone defaults to a 250 GB volume cap; production guidance is 1.2–1.5 TB."
  else bad "Free disk: ${disk} GB is below the documented ${MIN_DISK_GI} GB minimum."; fi

  # --- Ports 80/443 must be free for the ingress, unless k3s already holds them
  local port
  for port in 80 443; do
    if ss -lnt "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
      if ss -lntp "sport = :${port}" 2>/dev/null | grep -qE 'k3s|traefik|svclb|nginx'; then
        ok "Port ${port} is held by the cluster (expected on a re-run)."
      else
        bad "Port ${port} is in use by something other than the cluster."
        hint "Identify it with: sudo ss -lntp 'sport = :${port}'"
      fi
    else
      ok "Port ${port} is free."
    fi
  done

  log "Preflight: outbound connectivity (trustlist)"
  local url code unreachable=0
  for url in "${TRUSTLIST_HOSTS[@]}"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null || true)"
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    if [[ "$code" != "000" ]]; then
      ok "$(printf '%-46s HTTP %s' "$url" "$code")"
    else
      unreachable=$((unreachable+1))
      if [[ "$url" == *platform-registry* || "$url" == *registry-1.docker.io* ]]; then
        bad "Unreachable: ${url} (required to pull images)"
      else
        warn "Unreachable: ${url}"
      fi
    fi
  done
  if (( unreachable > 0 )); then
    hint "Behind a proxy? Re-run with --proxy-https http://proxy:8080 (and export the same for this shell)."
    hint "Full list: https://docs.invicti.com/ip/trustlist-on-premises"
  fi

  log "Preflight: tooling"
  local t
  for t in curl tar; do
    command -v "$t" >/dev/null && ok "$t present" || bad "$t missing"
  done
  if command -v helm >/dev/null; then
    local hv; hv="$(helm version --short 2>/dev/null || echo unknown)"
    if [[ "$(helm_major)" == "3" ]]; then ok "Helm ${hv}"
    elif [[ "$(helm_major)" == "4" ]]; then
      if helm version --short 2>/dev/null | grep -q 'v4\.1\.1'; then
        warn "Helm ${hv}. Only 4.1.1 is supported on the v4 line; 3.x is safer."
      else
        bad "Helm ${hv} is not supported by this chart (v4 releases after 4.1.1 break KEDA ownership)."
        hint "This script can replace it with Helm ${HELM_VERSION} during install."
      fi
    fi
  else
    info "Helm not installed; the install command will fetch Helm ${HELM_VERSION}."
  fi
  if command -v kubectl >/dev/null; then ok "kubectl present"; else info "kubectl not installed (k3s provides it)."; fi

  log "Preflight: cluster"
  if setup_kubeconfig; then
    local nodes ready
    nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready || true)"
    ok "Cluster reachable: ${ready}/${nodes} node(s) Ready"
    if kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -q true; then
      ok "Default StorageClass: $(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)"
    else
      bad "No default StorageClass. PersistentVolumeClaims will not bind."
      hint "k3s ships local-path by default; on other clusters mark one StorageClass default."
    fi
    if kubectl get svc traefik -n kube-system >/dev/null 2>&1; then
      warn "k3s's bundled Traefik occupies ports 80/443."
      hint "The install command offers to disable it; the chart's nginx-service needs those ports."
    fi
    if kubectl get crd scaledjobs.keda.sh >/dev/null 2>&1; then
      if [[ "$KEDA_EXISTING" == "true" ]]; then
        ok "KEDA CRDs present and --keda-existing was passed."
      else
        warn "KEDA CRDs already exist in this cluster."
        hint "If another product manages KEDA, re-run with --keda-existing so the chart reuses it."
        hint "If these are leftovers from a previous Invicti install, run: $SCRIPT_NAME uninstall --purge"
      fi
    fi
    if release_exists; then
      warn "Release '${RELEASE}' already exists in namespace '${NAMESPACE}'."
      hint "'install' will upgrade it in place. To start clean: $SCRIPT_NAME uninstall --purge"
    fi
  else
    info "No cluster yet. The install command can set up single-node k3s."
  fi

  log "Preflight summary"
  info "Failures: ${FAILURES}    Warnings: ${WARNINGS}"
  if (( FAILURES > 0 )); then
    if [[ "$FORCE" == "true" ]]; then
      warn "Continuing despite ${FAILURES} failure(s) because --force was given."
    else
      die "${FAILURES} requirement(s) not met. Fix the [fail] items, or re-run with --force."
    fi
  else
    ok "All hard requirements met."
  fi
}

maybe_expand_disk() {
  command -v vgs >/dev/null 2>&1 || return 0
  local vg_free root_lv
  vg_free="$($SUDO vgs --noheadings -o vg_free --units g 2>/dev/null | tr -dc '0-9.' | cut -d. -f1 || true)"
  root_lv="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ "$vg_free" =~ ^[0-9]+$ ]] || return 0
  (( vg_free > 5 )) || return 0
  [[ "$root_lv" == /dev/mapper/* ]] || return 0

  warn "${vg_free} GB of the volume group is unallocated (Ubuntu's guided LVM default)."
  hint "This caps the node's ephemeral-storage and is a common cause of unschedulable pods."
  case "$EXPAND_DISK" in
    no)  hint "Reclaim it later with: sudo lvextend -r -l +100%FREE ${root_lv}"; return 0 ;;
    yes) ;;
    *)   if [[ "$COMMAND" != "install" ]]; then
           hint "Reclaim it with: sudo lvextend -r -l +100%FREE ${root_lv}"; return 0
         fi
         confirm "Extend ${root_lv} to use the remaining ${vg_free} GB now?" || {
           hint "Skipped. Reclaim later with: sudo lvextend -r -l +100%FREE ${root_lv}"; return 0; }
         ;;
  esac
  need_root
  log "Reclaiming ${vg_free} GB of unallocated volume group space"
  run $SUDO lvextend -r -l +100%FREE "$root_lv"
  ok "Root filesystem is now $(disk_size_gi) GB, $(disk_free_gi) GB free."
}

#===============================================================================
#  Install
#===============================================================================

wait_for_apt() {
  local waited=0
  while $SUDO fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || $SUDO fuser /var/lib/apt/lists/lock  >/dev/null 2>&1; do
    (( waited == 0 )) && info "Waiting for another apt process to release the dpkg lock ..."
    sleep 5; waited=$((waited+5))
    (( waited > 600 )) && die "apt has been locked for 10 minutes. Check: ps aux | grep -E 'apt|unattended'"
  done
}

install_packages() {
  command -v apt-get >/dev/null || { info "Not an apt system; skipping package step."; return 0; }
  log "Base packages"
  # Skip entirely when everything is already installed, so a re-install on a
  # prepared host does not need root at all.
  local pkg missing=()
  for pkg in curl tar ca-certificates open-iscsi lvm2 jq; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" || missing+=("$pkg")
  done
  if (( ${#missing[@]} == 0 )) && [[ "$SKIP_UPGRADE" == "true" ]]; then
    ok "All base packages already installed."
    return 0
  fi
  info "Missing: ${missing[*]:-none}"
  need_root
  export DEBIAN_FRONTEND=noninteractive
  local opts=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  wait_for_apt; run $SUDO apt-get update -qq
  if [[ "$SKIP_UPGRADE" != "true" ]]; then
    info "Applying OS updates (this can take several minutes) ..."
    wait_for_apt; run $SUDO apt-get "${opts[@]}" full-upgrade
  fi
  wait_for_apt
  (( ${#missing[@]} > 0 )) && run $SUDO apt-get "${opts[@]}" install "${missing[@]}"
  ok "Base packages present."
  [[ -f /var/run/reboot-required ]] && warn "A reboot is pending from the OS update; continue now, reboot when convenient."
  return 0
}

install_k3s() {
  if command -v k3s >/dev/null && $SUDO systemctl is-active --quiet k3s 2>/dev/null; then
    ok "k3s already installed and running."
    return 0
  fi
  if [[ "$INSTALL_K3S" == "no" ]]; then
    die "No cluster available and --no-k3s was given. Point KUBECONFIG at a cluster, or allow k3s."
  fi
  if [[ "$INSTALL_K3S" == "auto" && "$ASSUME_YES" != "true" ]]; then
    confirm "No Kubernetes cluster found. Install single-node k3s on this host?" \
      || die "Aborted. Provide a cluster via KUBECONFIG, or re-run with --install-k3s."
  fi
  need_root
  log "Installing k3s"
  # Pass proxy settings to the service too, otherwise image pulls fail on a
  # proxied network even though the interactive shell can reach the registry.
  if [[ -n "${PROXY_HTTPS:-${https_proxy:-${HTTPS_PROXY:-}}}" ]]; then
    info "Proxy detected — writing /etc/systemd/system/k3s.service.env"
    $SUDO tee /etc/systemd/system/k3s.service.env >/dev/null <<EOF
HTTP_PROXY=${PROXY_HTTP:-${http_proxy:-${HTTP_PROXY:-}}}
HTTPS_PROXY=${PROXY_HTTPS:-${https_proxy:-${HTTPS_PROXY:-}}}
NO_PROXY=${PROXY_NOPROXY},10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
EOF
  fi
  # --disable=traefik is essential: k3s's bundled Traefik claims hostPorts 80/443
  # through its own svclb DaemonSet. The chart's nginx-service is also a
  # LoadBalancer on 443, so its svclb pod would sit Pending forever and the
  # platform would never get an external address.
  run bash -c 'curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable=traefik" sh -'
  hash -r
  install_kubeconfig_for_user
  info "Waiting for the node to become Ready ..."
  local i
  for i in $(seq 1 72); do
    kubectl get nodes 2>/dev/null | grep -qw Ready && break
    (( i == 72 )) && die "Node not Ready after 6 minutes. Inspect: sudo journalctl -u k3s -e"
    sleep 5
  done
  ok "k3s ready: $(kubectl get nodes --no-headers | awk '{print $1, $5}')"
}

# k3s ships Traefik as an ingress. It binds hostPorts 80/443 via svclb, which
# starves the chart's own nginx-service LoadBalancer. Retire it, keeping the
# skip-file so k3s does not re-apply the bundled manifest on restart.
disable_traefik() {
  kubectl get svc traefik -n kube-system >/dev/null 2>&1 || return 0
  warn "k3s's bundled Traefik is holding ports 80/443."
  hint "The chart publishes nginx-service as a LoadBalancer on 443. While Traefik"
  hint "owns those host ports the platform can never receive an external address."
  if [[ "$ASSUME_YES" != "true" ]]; then
    confirm "Disable the bundled Traefik so Invicti can bind 80/443?" || {
      warn "Leaving Traefik in place; expect nginx-service to stay <pending>."
      hint "Alternative: install with --service-type NodePort --node-port 30443"
      return 0
    }
  fi
  need_root
  log "Disabling the bundled Traefik"
  $SUDO mkdir -p /var/lib/rancher/k3s/server/manifests
  $SUDO touch /var/lib/rancher/k3s/server/manifests/traefik.yaml.skip
  kubectl -n kube-system delete helmchart traefik            --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system delete helmchartconfig traefik      --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system delete svc traefik                  --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system delete deployment traefik           --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system delete daemonset -l svccontroller.k3s.cattle.io/svcname=traefik --ignore-not-found >/dev/null 2>&1 || true
  ok "Traefik disabled; ports 80/443 are free for the platform."
}

install_helm() {
  local cur=""
  command -v helm >/dev/null && cur="$(helm_major || true)"
  if [[ "$cur" == "3" ]]; then
    ok "Helm $(helm version --short) already present."
    return 0
  fi
  need_root
  log "Installing Helm ${HELM_VERSION}"
  if [[ -n "$cur" ]]; then
    warn "Helm ${cur} found. The chart requires Helm 3.8+ (v4 after 4.1.1 breaks KEDA ownership); replacing it."
  fi
  # Ubuntu's snap 'helm' is on the v4 line — remove it or it keeps winning $PATH.
  if command -v snap >/dev/null && snap list helm >/dev/null 2>&1; then
    info "Removing the snap helm package (it ships Helm 4)."
    run $SUDO snap remove helm
  fi
  run bash -c "curl -fsSL -o /tmp/get-helm-3 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod +x /tmp/get-helm-3"
  run $SUDO env DESIRED_VERSION="$HELM_VERSION" /tmp/get-helm-3
  hash -r
  [[ "$(helm_major)" == "3" ]] || die "Still resolving to Helm $(helm version --short). Ensure /usr/local/bin precedes /snap/bin in PATH."
  ok "Helm $(helm version --short) installed."
}

collect_credentials() {
  [[ -n "$INVICTI_EMAIL" ]] || {
    [[ "$ASSUME_YES" == "true" ]] && die "--email is required (or set INVICTI_EMAIL)."
    read -rp "    Invicti account email: " INVICTI_EMAIL
  }
  [[ -n "$INVICTI_LICENSE_KEY" ]] || {
    [[ "$ASSUME_YES" == "true" ]] && die "--license is required (or set INVICTI_LICENSE_KEY)."
    read -rsp "    Invicti license key (hidden): " INVICTI_LICENSE_KEY; echo
  }
  [[ -n "$INVICTI_EMAIL" && -n "$INVICTI_LICENSE_KEY" ]] || die "Email and license key are both required."
}

registry_login() {
  log "Authenticating to ${REGISTRY}"
  info "Username is your Invicti email; the password is your license key."
  # A fixed /tmp path breaks when a previous run created it as root.
  local errf; errf="$(mktemp)"
  if ! printf '%s' "$INVICTI_LICENSE_KEY" | helm registry login "$REGISTRY" \
        --username "$INVICTI_EMAIL" --password-stdin 2>"$errf"; then
    cat "$errf" >&2 || true
    rm -f "$errf"
    die "Registry login failed. Verify the email and license key, and that ${REGISTRY} is reachable."
  fi
  rm -f "$errf"
  ok "Registry login succeeded."
}

pull_chart() {
  log "Fetching the chart"
  mkdir -p "$WORKDIR" 2>/dev/null || { need_root; $SUDO mkdir -p "$WORKDIR"; }
  # An earlier run under sudo leaves these owned by root; make sure the current
  # user can replace them rather than failing halfway through a re-run.
  if [[ -e "$WORKDIR/onpremises" && ! -w "$WORKDIR/onpremises" ]]; then
    need_root
    $SUDO rm -rf "$WORKDIR/onpremises" "$WORKDIR"/onpremises-*.tgz
    $SUDO chown -R "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$WORKDIR" 2>/dev/null || true
  fi
  cd "$WORKDIR"
  rm -rf onpremises onpremises-*.tgz 2>/dev/null || { need_root; $SUDO rm -rf onpremises onpremises-*.tgz; }
  local args=("$CHART_REPO")
  [[ -n "$CHART_VERSION" ]] && args+=(--version "$CHART_VERSION")
  run helm pull "${args[@]}"
  run tar xf onpremises-*.tgz
  # Running under sudo would otherwise leave a root-owned chart that a later
  # non-root invocation cannot clean up.
  if [[ "$(id -u)" -eq 0 && "$TARGET_USER" != "root" ]]; then
    chown -R "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$WORKDIR" 2>/dev/null || true
  fi
  CHART_LOCAL="$WORKDIR/onpremises"
  CHART_VERSION_ACTUAL="$(awk '/^version:/{print $2; exit}' "$CHART_LOCAL/Chart.yaml" 2>/dev/null || echo unknown)"
  ok "Chart ${CHART_VERSION_ACTUAL} extracted to ${CHART_LOCAL}"
}

# The chart ships either size-tagged profiles (values-resources-recommended-12gi.yaml)
# or named ones (basic / none / recommended). 'recommended' is sized for a
# high-availability multi-node cluster and will strand pods on a single node.
select_profile() {
  log "Resource profile"
  local profiles=()
  mapfile -t profiles < <(find "$CHART_LOCAL" -maxdepth 2 -name 'values-resources-*.yaml' 2>/dev/null | sort)
  if (( ${#profiles[@]} == 0 )); then
    warn "No values-resources-*.yaml in this chart; installing with chart defaults (no resource requests)."
    RESOURCE_PROFILE=""
    return 0
  fi
  info "Profiles in this chart:"
  local p; for p in "${profiles[@]}"; do info "  - $(basename "$p")"; done

  if [[ -n "$RESOURCE_PROFILE" ]]; then
    [[ -f "$RESOURCE_PROFILE" ]] || die "--profile not found: ${RESOURCE_PROFILE}"
    ok "Using the profile you specified: $(basename "$RESOURCE_PROFILE")"
    return 0
  fi

  # Reuse whatever profile the last successful deploy settled on. Without this,
  # an upgrade re-derives from RAM and can pick a heavier profile than the one
  # the node actually tolerated, stranding pods that were previously fine.
  if [[ -r "$STATE_FILE" ]]; then
    local remembered
    remembered="$(grep -E '^profile=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true)"
    if [[ -n "$remembered" && -f "$CHART_LOCAL/$remembered" ]]; then
      RESOURCE_PROFILE="$CHART_LOCAL/$remembered"
      ok "Reusing the profile from the last successful deploy: ${remembered}"
      for p in "${profiles[@]}"; do
        [[ "$(basename "$p")" == "values-resources-none.yaml" ]] && P_NONE="$p"
      done
      return 0
    fi
  fi

  local p_basic="" p_none="" p_recommended=""
  for p in "${profiles[@]}"; do
    case "$(basename "$p")" in
      values-resources-basic.yaml)       p_basic="$p" ;;
      values-resources-none.yaml)        p_none="$p" ;;
      values-resources-recommended.yaml) p_recommended="$p" ;;
    esac
  done
  P_NONE="$p_none"

  local budget=$(( MEM_GI - 3 )); (( budget < 1 )) && budget=1
  local best=0 size
  for p in "${profiles[@]}"; do
    size="$(basename "$p" | grep -oiE '[0-9]+gi' | grep -oE '[0-9]+' | head -1 || true)"
    [[ -z "$size" ]] && continue
    if (( size <= budget && size > best )); then best="$size"; RESOURCE_PROFILE="$p"; fi
  done

  if [[ -n "$RESOURCE_PROFILE" ]]; then
    info "Largest size-tagged profile that fits ${budget} Gi: ${best}gi"
  elif (( MEM_GI >= 24 )) && [[ -n "$p_recommended" ]]; then
    RESOURCE_PROFILE="$p_recommended"; info "${MEM_GI} Gi node — using 'recommended'."
  elif [[ -n "$p_basic" ]]; then
    RESOURCE_PROFILE="$p_basic";       info "${MEM_GI} Gi node — using 'basic'."
  elif [[ -n "$p_none" ]]; then
    RESOURCE_PROFILE="$p_none"
    warn "Only 'none' and 'recommended' available; 'recommended' is multi-node sized, so using 'none'."
  else
    RESOURCE_PROFILE="${profiles[0]}"
    warn "No profile recognised by name; using $(basename "$RESOURCE_PROFILE")."
  fi
  ok "Profile: $(basename "$RESOURCE_PROFILE")"
}

# Render values.yaml from the flags. Written 0600 because it holds the license
# key and potentially SMTP and database passwords.
# The chart keeps 4 DAST scanners warm by default (keda.scanners.scaledJob.
# minReplicaCount). Each one requests 2 CPU + 6Gi plus a 1Gi sidecar, so an
# idle cluster needs ~28Gi before a single scan runs. On a smaller node the
# surplus scanners sit Pending forever, which looks like a broken install.
tune_scanner_replicas() {
  [[ "$SCANNER_MIN_REPLICAS" == "auto" ]] || return 0
  local per=7 overhead=11 budget fit
  budget=$(( ${MEM_GI:-0} - overhead ))
  fit=$(( budget / per ))
  (( fit < 1 )) && fit=1
  (( fit > 4 )) && fit=4
  if (( fit < 4 )); then
    SCANNER_MIN_REPLICAS="$fit"
    warn "Reducing warm DAST scanners from 4 to ${fit} to fit a ${MEM_GI} Gi node."
    hint "Each warm scanner reserves ~${per} Gi. Four of them need ~28 Gi before any scan starts,"
    hint "so on this host the extra ones would sit Pending forever."
    hint "Override with --scanner-min-replicas <n>, or 'default' to keep the chart value."
  else
    SCANNER_MIN_REPLICAS="default"
  fi
}

write_values() {
  log "Rendering values.yaml"
  tune_scanner_replicas
  mkdir -p "$WORKDIR"
  local tmp; tmp="$(mktemp)"
  {
    printf 'global:\n'
    printf '  email_address: %s\n' "$INVICTI_EMAIL"
    printf '  license_key: %s\n'   "$INVICTI_LICENSE_KEY"
    printf '  app:\n'
    printf '    web_application_host: %s\n' "$PLATFORM_HOST"

    if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
      printf '    ssl:\n      fullchain: |\n'
      sed 's/^/        /' "$TLS_CERT"
      printf '      privkey: |\n'
      sed 's/^/        /' "$TLS_KEY"
    fi

    if [[ "$KEDA_EXISTING" == "true" ]]; then
      printf '  keda:\n    enabled: false\n'
    fi

    if [[ -n "$SMTP_HOST" ]]; then
      printf '  smtp:\n'
      printf '    engine: "%s"\n'      "$SMTP_ENGINE"
      printf '    host: "%s"\n'        "$SMTP_HOST"
      printf '    port: %s\n'          "$SMTP_PORT"
      printf '    mail: "%s"\n'        "${SMTP_MAIL:-noreply@${PLATFORM_HOST}}"
      printf '    displayname: "%s"\n' "$SMTP_DISPLAYNAME"
      [[ -n "$SMTP_USERNAME" ]] && printf '    username: "%s"\n' "$SMTP_USERNAME"
      [[ -n "$SMTP_PASSWORD" ]] && printf '    password: "%s"\n' "$SMTP_PASSWORD"
      printf '    security: "%s"\n'    "$SMTP_SECURITY"
    fi

    if [[ -n "$PROXY_HTTPS$PROXY_HTTP" ]]; then
      printf '  proxy:\n'
      printf '    http_proxy: "%s"\n'  "${PROXY_HTTP:-$PROXY_HTTPS}"
      printf '    https_proxy: "%s"\n' "${PROXY_HTTPS:-$PROXY_HTTP}"
      printf '    no_proxy: "%s"\n'    "$PROXY_NOPROXY"
    fi

    if [[ -n "$DB_HOST" ]]; then
      printf '  data:\n'
      printf '    databaseUser: "%s"\n'       "$DB_USER"
      printf '    databasePassword: "%s"\n'   "$DB_PASSWORD"
      printf '    databaseHost: "%s"\n'       "$DB_HOST"
      printf '    databasePort: "%s"\n'       "$DB_PORT"
      printf '    databaseCert: "%s"\n'       "$DB_CERT"
      printf '    databaseSslEnabled: %s\n'   "$DB_SSL"
    fi

    if [[ -n "$JIRA_CLIENT_ID" ]]; then
      printf '  integrations:\n    jira:\n'
      printf '      oauth20_client_id: "%s"\n'     "$JIRA_CLIENT_ID"
      printf '      oauth20_client_secret: "%s"\n' "$JIRA_CLIENT_SECRET"
    fi

    if [[ -n "$SCANNER_MIN_REPLICAS" && "$SCANNER_MIN_REPLICAS" != "default" ]]; then
      printf 'headless-dast:\n  keda:\n    scanners:\n      scaledJob:\n        minReplicaCount: %s\n' "$SCANNER_MIN_REPLICAS"
    fi

    if [[ -n "$REGISTRY_ADDRESS" ]]; then
      printf '  image:\n'
      printf '    path: "%s"\n'             "$REGISTRY_PATH"
      [[ -n "$REGISTRY_PROXY_URL" ]] && printf '    proxy_remote_url: "%s"\n' "$REGISTRY_PROXY_URL"
      printf '    registryAddress: "%s"\n'  "$REGISTRY_ADDRESS"
    fi

    if [[ -n "$SERVICE_TYPE" ]]; then
      printf 'nginx:\n  service:\n    type: "%s"\n' "$SERVICE_TYPE"
      [[ "$SERVICE_TYPE" == "NodePort" ]] && printf '    nodePort: %s\n' "$NODE_PORT"
    fi
  } > "$tmp"

  install -m 600 "$tmp" "$VALUES_FILE"
  rm -f "$tmp"
  chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$VALUES_FILE" 2>/dev/null || true
  ok "${VALUES_FILE} written (mode 0600)."
  info "Contains the license key$( [[ -n "$SMTP_PASSWORD" ]] && printf ' and SMTP password')$( [[ -n "$DB_PASSWORD" ]] && printf ' and database password') — redact before sharing."
  [[ -n "$SMTP_HOST" ]] || warn "No SMTP configured: invitations, password resets and scan alerts will not send."
  if [[ -n "$REGISTRY_ADDRESS" ]]; then
    warn "Custom image registry set to ${REGISTRY_ADDRESS}."
    hint "Some third-party subcharts ignore global.image.registryAddress and expose their own"
    hint "registry key (imageRegistry, image.registry, ...). Any that do will fall back to their"
    hint "upstream registry and fail with ImagePullBackOff on an air-gapped cluster."
    hint "Add matching per-subchart overrides via --values <file>. See the chart's values.yaml."
  fi
}

helm_value_args() {
  VALUE_ARGS=()
  [[ -n "$RESOURCE_PROFILE" ]] && VALUE_ARGS+=(--values "$RESOURCE_PROFILE")
  if [[ "$OPENSHIFT" == "true" ]]; then
    local ocp="$CHART_LOCAL/values-openshift.yaml"
    [[ -f "$ocp" ]] || die "--openshift given but values-openshift.yaml is not in this chart."
    VALUE_ARGS+=(--values "$ocp")
  fi
  VALUE_ARGS+=(--values "$VALUES_FILE")
  [[ -n "$EXTRA_VALUES" ]] && VALUE_ARGS+=(--values "$EXTRA_VALUES")
  # --set-file takes precedence over anything embedded in values.yaml.
  if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
    VALUE_ARGS+=(--set-file "global.app.ssl.fullchain=$TLS_CERT"
                 --set-file "global.app.ssl.privkey=$TLS_KEY")
  fi
}

# Some components are cluster-scoped (CRDs, ClusterRoles, and on OpenShift the
# DAST scanner SCC) and need cluster-admin. Where the person deploying is only
# namespace-scoped, the chart ships values-prereqs.yaml / values-application.yaml
# so a cluster admin can install phase 1 and the app owner phase 2.
deploy_two_phase() {
  local prereqs="$CHART_LOCAL/values-prereqs.yaml"
  local appvals="$CHART_LOCAL/values-application.yaml"
  [[ -f "$prereqs" && -f "$appvals" ]] \
    || die "--two-phase needs values-prereqs.yaml and values-application.yaml in the chart; this chart has neither."
  helm_value_args
  log "Phase 1 of 2: cluster-scoped prerequisites (requires cluster-admin)"
  run helm upgrade --install "${RELEASE}-prereqs" "$CHART_LOCAL" \
      --namespace "$NAMESPACE" --create-namespace \
      --values "$prereqs" "${VALUE_ARGS[@]}" --timeout "$HELM_TIMEOUT"
  ok "Prerequisites installed."
  log "Phase 2 of 2: the application"
  run helm upgrade --install "$RELEASE" "$CHART_LOCAL" \
      --namespace "$NAMESPACE" \
      --values "$appvals" "${VALUE_ARGS[@]}" --timeout "$HELM_TIMEOUT"
  ok "Application installed."
}

deploy_chart() {
  if [[ "$TWO_PHASE" == "true" ]]; then deploy_two_phase; return; fi
  helm_value_args
  log "Deploying ${RELEASE} into namespace ${NAMESPACE}"
  info "Chart: ${CHART_LOCAL}   profile: $( [[ -n "$RESOURCE_PROFILE" ]] && basename "$RESOURCE_PROFILE" || echo 'chart defaults')"
  # Deliberately no --wait: Helm would block silently for the whole timeout while
  # pods sit Pending. Polling ourselves surfaces the real reason within minutes.
  run helm upgrade --install "$RELEASE" "$CHART_LOCAL" \
      --namespace "$NAMESPACE" --create-namespace \
      "${VALUE_ARGS[@]}" \
      --timeout "$HELM_TIMEOUT"
}

# Record what actually worked so later runs are reproducible. Without this an
# upgrade re-derives the profile from RAM and can pick a heavier one than the
# node tolerated, stranding pods that were previously healthy.
# Lowering the ScaledJob's minReplicaCount does not retire Jobs KEDA already
# created. Their pods stay Pending forever because the node cannot fit them,
# which looks like a broken deployment and blocks other pods from scheduling.
prune_unschedulable_scanners() {
  local stuck job pod
  stuck="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
           | awk '$1 ~ /^dast-scanner-/ && $3 == "Pending" {print $1}')" || true
  [[ -n "$stuck" ]] || return 0
  local n; n="$(printf '%s\n' "$stuck" | grep -c . || true)"
  warn "${n} DAST scanner pod(s) cannot be scheduled on this node."
  hint "These are warm scanners KEDA created before the replica count was lowered."
  hint "They will never schedule here, so the owning Jobs are being removed."
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    # Only touch pods that are genuinely unschedulable, never queued work.
    kubectl get pod "$pod" -n "$NAMESPACE" \
      -o jsonpath='{range .status.conditions[?(@.type=="PodScheduled")]}{.reason}{end}' 2>/dev/null \
      | grep -q Unschedulable || continue
    job="$(kubectl get pod "$pod" -n "$NAMESPACE" \
           -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Job")].name}' 2>/dev/null || true)"
    if [[ -n "$job" ]]; then
      kubectl delete job "$job" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 \
        && info "  removed stale scanner job ${job}"
    else
      kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    fi
  done <<< "$stuck"
  ok "Stale scanner jobs pruned; KEDA will recreate what the node can hold."
}

# On a single node a rolling update can deadlock. The default Deployment
# strategy (maxSurge=1, maxUnavailable=0) requires the replacement pod to be
# Ready *before* the outgoing pod is removed, so both must fit at once. When the
# node cannot hold two copies the rollout never converges and Helm times out.
# Switching that Deployment to maxSurge=0/maxUnavailable=1 makes Kubernetes stop
# the old pod first, which is the correct trade-off on a single-node install.
# Helm restores the chart's own strategy on the next upgrade.
unwedge_rollouts() {
  local stuck pod rs dep acted=0
  stuck="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
           | awk '$3 == "Pending" {print $1}')" || true
  [[ -n "$stuck" ]] || return 0

  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    kubectl get pod "$pod" -n "$NAMESPACE" \
      -o jsonpath='{range .status.conditions[?(@.type=="PodScheduled")]}{.reason}{.message}{end}' 2>/dev/null \
      | grep -qi 'Unschedulable.*Insufficient memory' || continue

    rs="$(kubectl get pod "$pod" -n "$NAMESPACE" \
          -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].name}' 2>/dev/null || true)"
    [[ -n "$rs" ]] || continue
    dep="$(kubectl get rs "$rs" -n "$NAMESPACE" \
          -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)"
    [[ -n "$dep" ]] || continue

    # Only act when an older pod of the same Deployment is still holding memory.
    kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
      | awk -v d="$dep" '$1 ~ d && $3 == "Running"' | grep -q . || continue

    if (( acted == 0 )); then
      warn "A rolling update is deadlocked: this node cannot hold the outgoing and incoming pods together."
      hint "Switching the affected Deployments to stop-then-start (maxSurge=0, maxUnavailable=1)."
      hint "That component is briefly unavailable while it restarts."
      acted=1
    fi
    kubectl patch deployment "$dep" -n "$NAMESPACE" --type=strategic \
      -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}' \
      >/dev/null 2>&1 && info "  ${dep}: strategy set to stop-then-start"
  done <<< "$stuck"

  (( acted == 1 )) && ok "Deadlocked rollouts released." || true
  return 0
}

save_state() {
  local rc="${1:-0}"
  (( rc == 0 )) || return 0
  [[ -n "${RESOURCE_PROFILE:-}" ]] || return 0
  mkdir -p "$WORKDIR" 2>/dev/null || return 0
  {
    printf 'profile=%s\n'  "$(basename "$RESOURCE_PROFILE")"
    printf 'chart=%s\n'    "${CHART_VERSION_ACTUAL:-unknown}"
    printf 'scanners=%s\n' "${SCANNER_MIN_REPLICAS:-auto}"
    printf 'updated=%s\n'  "$(date -Is)"
  } > "$STATE_FILE" 2>/dev/null || true
  chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$STATE_FILE" 2>/dev/null || true
}

cmd_install() {
  preflight
  collect_credentials
  install_packages
  if ! setup_kubeconfig; then install_k3s; fi
  install_helm
  require_cluster
  disable_traefik
  registry_login
  pull_chart
  select_profile
  write_values

  # Resolve the hostname locally so the reachability check and in-VM browsing work.
  if ! grep -qE "[[:space:]]${PLATFORM_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    need_root
    printf '127.0.0.1    %s\n' "$PLATFORM_HOST" | $SUDO tee -a /etc/hosts >/dev/null
    ok "Added '${PLATFORM_HOST}' to /etc/hosts."
  fi

  deploy_chart
  local rc=0
  set +e; settle; rc=$?; set -e

  if (( rc == 1 )) && [[ "$AUTO_FALLBACK" == "true" && -n "${P_NONE:-}" && "$RESOURCE_PROFILE" != "${P_NONE:-}" ]]; then
    warn "Retrying once with the 'none' profile (no requests or limits)."
    hint "Every pod will schedule, but nothing protects the node from OOM. Fine for a lab, not production."
    RESOURCE_PROFILE="$P_NONE"
    deploy_chart
    prune_unschedulable_scanners
    set +e; settle; rc=$?; set -e
  fi

  save_state "$rc"
  report_result "$rc"
}

#===============================================================================
#  Uninstall
#===============================================================================
#  Levels, because "uninstall" means different things to different people:
#    (default)         remove the Helm release only; data survives
#    --purge-data      also delete PVCs and the namespace  → all scan data gone
#    --purge           the above plus cluster-scoped leftovers (KEDA CRDs,
#                      ClusterRoles, webhooks). This is what makes a later
#                      re-install work; without it Helm fails on ownership.
#    --purge-all       the above plus k3s itself
#===============================================================================

# Anything cluster-scoped that Helm stamped for this release.
cluster_scoped_leftovers() {
  local kinds=(
    clusterrole clusterrolebinding customresourcedefinition
    validatingwebhookconfiguration mutatingwebhookconfiguration
    apiservice priorityclass storageclass
  )
  local k
  for k in "${kinds[@]}"; do
    kubectl get "$k" -o json 2>/dev/null | REL="$RELEASE" NS="$NAMESPACE" KIND="$k" python3 -c '
import json,sys,os
rel=os.environ["REL"]; ns=os.environ["NS"]; kind=os.environ["KIND"]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for i in d.get("items",[]):
    a=(i.get("metadata") or {}).get("annotations") or {}
    l=(i.get("metadata") or {}).get("labels") or {}
    if a.get("meta.helm.sh/release-name")==rel and a.get("meta.helm.sh/release-namespace")==ns:
        print(kind+"/"+i["metadata"]["name"])
    elif l.get("app.kubernetes.io/instance")==rel and l.get("app.kubernetes.io/managed-by")=="Helm":
        print(kind+"/"+i["metadata"]["name"])
' 2>/dev/null || true
  done
  # KEDA is a subchart; its CRDs are cluster-wide and often unlabelled.
  kubectl get crd -o name 2>/dev/null | grep -E 'keda\.sh$' || true
}

force_finalize_namespace() {
  # A namespace can wedge in Terminating when a CRD's controller is already gone
  # and finalizers never clear. Strip them.
  local ns="$1" i
  for i in $(seq 1 30); do
    kubectl get namespace "$ns" >/dev/null 2>&1 || return 0
    [[ "$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Terminating" ]] || { sleep 2; continue; }
    (( i < 5 )) && { sleep 2; continue; }
    warn "Namespace '${ns}' is stuck Terminating; clearing finalizers."
    kubectl get namespace "$ns" -o json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); d["spec"]["finalizers"]=[]; print(json.dumps(d))' \
      | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
    sleep 3
  done
  kubectl get namespace "$ns" >/dev/null 2>&1 && warn "Namespace '${ns}' still present; inspect: kubectl get all -n ${ns}"
  return 0
}

clear_pvc_finalizers() {
  local pvc
  for pvc in $(kubectl get pvc -n "$NAMESPACE" -o name 2>/dev/null); do
    kubectl patch "$pvc" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
  done
}

cmd_uninstall() {
  require_cluster
  log "Uninstall plan"
  info "Release   : ${RELEASE} (namespace ${NAMESPACE})"
  info "Delete data (PVCs + namespace) : $( [[ "$PURGE_DATA"    == "true" ]] && echo YES || echo no )"
  info "Delete cluster-scoped leftovers: $( [[ "$PURGE_CLUSTER" == "true" ]] && echo YES || echo no )"
  info "Remove k3s                     : $( [[ "$PURGE_K3S"     == "true" ]] && echo YES || echo no )"

  if [[ "$PURGE_DATA" == "true" ]]; then
    warn "This permanently deletes all scan data, users and configuration."
    hint "Take a backup first:  $SCRIPT_NAME backup"
    confirm "Proceed with destructive uninstall?" || die "Aborted."
  fi

  if helm status "${RELEASE}-prereqs" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Removing the two-phase prerequisites release"
    run helm uninstall "${RELEASE}-prereqs" -n "$NAMESPACE" --wait --timeout 10m || warn "Could not remove ${RELEASE}-prereqs."
  fi

  if release_exists; then
    # KEDA's warm DAST scanners are long-running Jobs that never complete on
    # their own. `helm uninstall --wait` blocks on them for the full timeout, so
    # stop the scaler and drop its Jobs first — uninstall then returns promptly.
    if kubectl get scaledjob -n "$NAMESPACE" >/dev/null 2>&1; then
      log "Stopping DAST scanner autoscaling"
      kubectl delete scaledjob --all -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1 || true
      kubectl delete jobs -n "$NAMESPACE" -l 'scaledjob.keda.sh/name' --timeout=60s >/dev/null 2>&1 \
        || kubectl get jobs -n "$NAMESPACE" --no-headers 2>/dev/null | awk '$1 ~ /^dast-scanner-/ {print $1}' \
             | xargs -r kubectl delete job -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1 || true
      ok "Scanner autoscaling stopped."
    fi
    log "Removing the Helm release"
    run helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 5m || warn "helm uninstall reported an error; continuing."
    ok "Release removed."
  else
    info "Release '${RELEASE}' not found; nothing to uninstall."
  fi

  if [[ "$PURGE_DATA" == "true" ]]; then
    if ns_exists; then
      log "Deleting persistent data"
      run kubectl delete pvc -n "$NAMESPACE" --all --timeout=180s || { warn "PVC deletion stalled; clearing finalizers."; clear_pvc_finalizers; }
      run kubectl delete namespace "$NAMESPACE" --timeout=180s || true
      force_finalize_namespace "$NAMESPACE"
      ok "Namespace and PVCs deleted."
    fi
    # Released PVs with a Retain policy linger and can block rebinding.
    local pvs
    pvs="$(kubectl get pv -o json 2>/dev/null | NS="$NAMESPACE" python3 -c '
import json,sys,os
ns=os.environ["NS"]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for i in d.get("items",[]):
    r=(i.get("spec") or {}).get("claimRef") or {}
    if r.get("namespace")==ns and (i.get("status") or {}).get("phase") in ("Released","Failed"):
        print(i["metadata"]["name"])
' 2>/dev/null || true)"
    if [[ -n "$pvs" ]]; then
      info "Removing released PersistentVolumes: $(echo "$pvs" | tr '\n' ' ')"
      # shellcheck disable=SC2086
      run kubectl delete pv $pvs --timeout=120s || true
    fi
  fi

  if [[ "$PURGE_CLUSTER" == "true" ]]; then
    log "Removing cluster-scoped leftovers"
    hint "These survive 'helm uninstall' and are the usual cause of a failed re-install."
    local leftovers
    leftovers="$(cluster_scoped_leftovers | sort -u)"
    if [[ -z "$leftovers" ]]; then
      ok "Nothing cluster-scoped left behind."
    else
      printf '%s\n' "$leftovers" | sed 's/^/        /'
      local obj failed=()
      while IFS= read -r obj; do
        [[ -z "$obj" ]] && continue
        if ! run kubectl delete "$obj" --timeout=60s --ignore-not-found >/dev/null 2>&1; then
          failed+=("$obj")
        fi
      done <<< "$leftovers"

      # A CRD will not delete while instances of it still carry finalizers, and
      # those instances are unreachable once their controller is gone. Strip the
      # finalizers, then retry.
      if (( ${#failed[@]} > 0 )); then
        info "Retrying ${#failed[@]} resource(s) after clearing finalizers ..."
        for obj in "${failed[@]}"; do
          # `kubectl get -o name` yields customresourcedefinition.apiextensions.k8s.io/<name>
          if [[ "$obj" == customresourcedefinition* ]]; then
            local crd="${obj#*/}" kind cr
            kind="$(kubectl get crd "$crd" -o jsonpath='{.spec.names.plural}.{.spec.group}' 2>/dev/null || true)"
            if [[ -n "$kind" ]]; then
              for cr in $(kubectl get "$kind" -A -o name 2>/dev/null || true); do
                kubectl patch "$cr" -A --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
              done
              kubectl get "$kind" -A --no-headers 2>/dev/null | awk '{print $1, $2}' | while read -r ns nm; do
                [[ -n "$nm" ]] && kubectl patch "$kind" "$nm" -n "$ns" --type=merge \
                  -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
              done
            fi
            kubectl patch crd "$crd" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
          fi
          kubectl delete "$obj" --timeout=60s --ignore-not-found >/dev/null 2>&1 \
            && info "  ${obj} removed on retry" \
            || warn "Could not delete ${obj} — remove it manually before reinstalling."
        done
      fi

      # Report honestly rather than claiming success.
      local still
      still="$(cluster_scoped_leftovers | sort -u || true)"
      if [[ -z "$still" ]]; then
        ok "Cluster-scoped resources removed."
      else
        warn "Some cluster-scoped resources survived:"
        printf '%s\n' "$still" | sed 's/^/        /'
        hint "Delete them manually, otherwise the next install may fail on ownership."
      fi
    fi
  else
    local remaining
    remaining="$(cluster_scoped_leftovers | sort -u | head -5)"
    if [[ -n "$remaining" ]]; then
      warn "Cluster-scoped resources remain (KEDA CRDs, ClusterRoles, ...)."
      hint "A future install may fail with an ownership conflict. Clean them with:"
      hint "  $SCRIPT_NAME uninstall --purge"
    fi
  fi

  helm registry logout "$REGISTRY" >/dev/null 2>&1 && ok "Logged out of ${REGISTRY}." || true

  if [[ "$PURGE_K3S" == "true" ]]; then
    log "Removing k3s"
    confirm "Really uninstall k3s from this host?" || die "Aborted."
    need_root
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
      run $SUDO /usr/local/bin/k3s-uninstall.sh
      ok "k3s removed."
    else
      warn "/usr/local/bin/k3s-uninstall.sh not found; k3s may not have been installed by this script."
    fi
    rm -rf "$TARGET_HOME/.kube" 2>/dev/null || true
  fi

  log "Uninstall complete"
  [[ "$PURGE_DATA" == "true" ]] || info "Data was preserved. Re-running 'install' will adopt the existing PVCs."
}

#===============================================================================
#  Backup / restore
#===============================================================================
#  Follows the vendor procedure: quiesce StatefulSets before touching PVCs,
#  export secrets but never the Helm release secret, and record the exact chart
#  version so the restore side installs a matching release.
#===============================================================================

HELPER_IMAGE="${HELPER_IMAGE:-busybox:stable}"

statefulsets()      { kubectl get statefulset -n "$NAMESPACE" -o name 2>/dev/null || true; }
deployments()       { kubectl get deployment  -n "$NAMESPACE" -o name 2>/dev/null || true; }

save_scale_state() {
  local out="$1" obj rep
  : > "$out"
  for obj in $(statefulsets) $(deployments); do
    rep="$(kubectl get "$obj" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    printf '%s %s\n' "$obj" "${rep:-0}" >> "$out"
  done
}

scale_all() {
  local replicas="$1" obj
  for obj in $(statefulsets) $(deployments); do
    kubectl scale "$obj" -n "$NAMESPACE" --replicas="$replicas" >/dev/null 2>&1 || true
  done
}

restore_scale_state() {
  local file="$1" obj rep
  [[ -r "$file" ]] || return 0
  while read -r obj rep; do
    [[ -z "$obj" ]] && continue
    kubectl scale "$obj" -n "$NAMESPACE" --replicas="$rep" >/dev/null 2>&1 || true
  done < "$file"
}

wait_pods_gone() {
  local i
  for i in $(seq 1 60); do
    [[ -z "$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v Completed || true)" ]] && return 0
    sleep 5
  done
  warn "Some pods are still terminating; PVC data may be less consistent."
}

# Stream one PVC's contents out through a short-lived helper pod. Works on any
# cluster and any storage class, unlike a host-path shortcut.
backup_one_pvc() {
  local pvc="$1" dest="$2" pod="invicti-backup-${RANDOM}"
  kubectl run "$pod" -n "$NAMESPACE" --restart=Never --image="$HELPER_IMAGE" \
    --overrides="$(cat <<JSON
{"spec":{"containers":[{"name":"c","image":"${HELPER_IMAGE}","command":["sleep","3600"],
"volumeMounts":[{"name":"d","mountPath":"/data"}]}],
"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"${pvc}"}}],"restartPolicy":"Never"}}
JSON
)" >/dev/null 2>&1 || { warn "Could not start helper pod for ${pvc}"; return 1; }
  kubectl wait --for=condition=Ready "pod/$pod" -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 || {
    warn "Helper pod for ${pvc} never became Ready"; kubectl delete pod "$pod" -n "$NAMESPACE" --force >/dev/null 2>&1 || true; return 1; }
  kubectl exec -n "$NAMESPACE" "$pod" -- tar cf - -C /data . 2>/dev/null > "$dest" || {
    warn "tar failed for ${pvc}"; kubectl delete pod "$pod" -n "$NAMESPACE" --force >/dev/null 2>&1 || true; return 1; }
  kubectl delete pod "$pod" -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true
  return 0
}

restore_one_pvc() {
  local pvc="$1" src="$2" pod="invicti-restore-${RANDOM}"
  kubectl run "$pod" -n "$NAMESPACE" --restart=Never --image="$HELPER_IMAGE" \
    --overrides="$(cat <<JSON
{"spec":{"containers":[{"name":"c","image":"${HELPER_IMAGE}","command":["sleep","3600"],
"volumeMounts":[{"name":"d","mountPath":"/data"}]}],
"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"${pvc}"}}],"restartPolicy":"Never"}}
JSON
)" >/dev/null 2>&1 || { warn "Could not start helper pod for ${pvc}"; return 1; }
  kubectl wait --for=condition=Ready "pod/$pod" -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 || {
    warn "Helper pod for ${pvc} never became Ready"; return 1; }
  kubectl exec -i -n "$NAMESPACE" "$pod" -- sh -c 'rm -rf /data/* /data/..?* 2>/dev/null; tar xf - -C /data' < "$src" || warn "untar failed for ${pvc}"
  kubectl delete pod "$pod" -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true
}

cmd_backup() {
  require_cluster
  release_exists || die "Release '${RELEASE}' not found in namespace '${NAMESPACE}'."
  mkdir -p "$BACKUP_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local staging; staging="$(mktemp -d)"
  local out="${BACKUP_FILE:-$BACKUP_DIR/invicti-backup-${stamp}.tar.gz}"

  log "Backing up ${RELEASE} from namespace ${NAMESPACE}"

  # 1. Configuration and release metadata
  info "Saving Helm values and release metadata ..."
  helm get values "$RELEASE" -n "$NAMESPACE" -o yaml > "$staging/helm-values.yaml" 2>/dev/null || true
  [[ -f "$VALUES_FILE" ]] && cp "$VALUES_FILE" "$staging/values.yaml"
  helm get manifest "$RELEASE" -n "$NAMESPACE" > "$staging/manifest.yaml" 2>/dev/null || true
  helm list -n "$NAMESPACE" -o json > "$staging/release.json" 2>/dev/null || true
  local chart_ver
  chart_ver="$(helm list -n "$NAMESPACE" -o json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["chart"] if d else "unknown")' 2>/dev/null || echo unknown)"

  # 2. Secrets — everything except the Helm release secrets, which must not be
  #    restored onto a new cluster (vendor guidance).
  info "Exporting secrets (excluding sh.helm.release.*) ..."
  kubectl get secrets -n "$NAMESPACE" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
d["items"]=[i for i in d.get("items",[])
            if not i["metadata"]["name"].startswith("sh.helm.release.")
            and i.get("type")!="helm.sh/release.v1"]
for i in d["items"]:
    m=i.get("metadata",{})
    for k in ("resourceVersion","uid","creationTimestamp","managedFields","ownerReferences","selfLink"):
        m.pop(k,None)
print(json.dumps(d,indent=1))
' > "$staging/secrets.json" 2>/dev/null || warn "Secret export failed."
  local nsec; nsec="$(python3 -c 'import json;print(len(json.load(open("'"$staging"'/secrets.json")).get("items",[])))' 2>/dev/null || echo 0)"
  ok "${nsec} secret(s) exported."

  # 3. Other namespaced state worth keeping
  kubectl get configmap,pvc -n "$NAMESPACE" -o yaml > "$staging/configmaps-pvcs.yaml" 2>/dev/null || true

  # 4. PVC data, quiesced
  local pvcs; pvcs="$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ "$INCLUDE_PVC" == "true" && -n "$pvcs" ]]; then
    save_scale_state "$staging/scale-state.txt"
    warn "Scaling workloads to zero for a consistent copy — the platform will be OFFLINE during this step."
    if ! confirm "Continue? (choose no to take a configuration-only backup)"; then
      info "Taking a configuration-only backup instead."
      INCLUDE_PVC=false
    fi
  fi

  if [[ "$INCLUDE_PVC" == "true" && -n "$pvcs" ]]; then
    mkdir -p "$staging/pvc"
    log "Quiescing workloads"
    scale_all 0
    wait_pods_gone
    ok "Workloads stopped."
    local pvc
    while IFS= read -r pvc; do
      [[ -z "$pvc" ]] && continue
      info "Archiving PVC ${pvc} ..."
      backup_one_pvc "$pvc" "$staging/pvc/${pvc}.tar" \
        && ok "  ${pvc}: $(du -h "$staging/pvc/${pvc}.tar" | cut -f1)" \
        || warn "  ${pvc}: skipped"
    done <<< "$pvcs"
    log "Restarting workloads"
    restore_scale_state "$staging/scale-state.txt"
    ok "Workloads scaled back up."
  else
    info "PVC data not included (configuration-only backup)."
  fi

  # 5. Manifest
  cat > "$staging/backup-info.txt" <<EOF
Invicti Platform on-premises backup
created            : $(date -Is)
host               : $(hostname)
script version     : ${SCRIPT_VERSION}
release            : ${RELEASE}
namespace          : ${NAMESPACE}
chart              : ${chart_ver}
web_application_host: ${PLATFORM_HOST}
includes PVC data  : ${INCLUDE_PVC}
kubernetes         : $(kubectl version -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown)
EOF

  tar czf "$out" -C "$staging" .
  chmod 600 "$out"
  chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$out" 2>/dev/null || true
  rm -rf "$staging"

  log "Backup complete"
  ok "${out}  ($(du -h "$out" | cut -f1))"
  warn "This archive contains secrets and your license key. Store it somewhere safe."
  hint "Restore with: $SCRIPT_NAME restore --from ${out}"
}

cmd_restore() {
  [[ -n "$RESTORE_FILE" ]] || die "--from <backup.tar.gz> is required."
  [[ -r "$RESTORE_FILE" ]] || die "Cannot read ${RESTORE_FILE}"
  require_cluster

  local staging; staging="$(mktemp -d)"
  if ! tar xzf "$RESTORE_FILE" -C "$staging" 2>/dev/null; then
    rm -rf "$staging"
    die "'${RESTORE_FILE}' is not a readable gzip archive."
  fi
  if [[ ! -f "$staging/backup-info.txt" ]]; then
    rm -rf "$staging"
    die "'${RESTORE_FILE}' is not an Invicti backup produced by this script (backup-info.txt missing)."
  fi

  log "Restoring from ${RESTORE_FILE}"
  sed 's/^/    /' "$staging/backup-info.txt"

  local has_pvc="false"
  [[ -d "$staging/pvc" ]] && has_pvc="true"

  warn "Restore overwrites the current contents of namespace '${NAMESPACE}'."
  confirm "Proceed?" || die "Aborted."

  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || run kubectl create namespace "$NAMESPACE"

  # 1. Secrets first — encryption keys must exist before the platform starts.
  if [[ -f "$staging/secrets.json" ]]; then
    log "Restoring secrets"
    run kubectl apply -n "$NAMESPACE" -f "$staging/secrets.json" || warn "Some secrets failed to apply."
    ok "Secrets restored."
  fi

  # 2. Reinstall the release using the captured values
  if [[ -f "$staging/values.yaml" ]]; then
    mkdir -p "$WORKDIR"; install -m 600 "$staging/values.yaml" "$VALUES_FILE"
    ok "values.yaml restored to ${VALUES_FILE}"
  elif [[ -f "$staging/helm-values.yaml" ]]; then
    mkdir -p "$WORKDIR"; install -m 600 "$staging/helm-values.yaml" "$VALUES_FILE"
    ok "Helm values restored to ${VALUES_FILE}"
  fi

  if ! release_exists; then
    log "Re-installing the release"
    collect_credentials
    registry_login
    pull_chart
    select_profile
    helm_value_args
    run helm upgrade --install "$RELEASE" "$CHART_LOCAL" \
        --namespace "$NAMESPACE" --create-namespace \
        "${VALUE_ARGS[@]}" --timeout "$HELM_TIMEOUT"
  else
    info "Release already present; keeping it and restoring data into it."
  fi

  # 3. PVC data, with workloads stopped
  if [[ "$has_pvc" == "true" ]]; then
    log "Restoring persistent data"
    save_scale_state "$staging/scale-state-current.txt"
    scale_all 0
    wait_pods_gone
    local f pvc
    for f in "$staging"/pvc/*.tar; do
      [[ -e "$f" ]] || continue
      pvc="$(basename "$f" .tar)"
      if kubectl get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1; then
        info "Restoring ${pvc} ..."
        restore_one_pvc "$pvc" "$f" && ok "  ${pvc} restored"
      else
        warn "  PVC ${pvc} does not exist in the target; skipping."
      fi
    done
    if [[ -f "$staging/scale-state.txt" ]]; then
      restore_scale_state "$staging/scale-state.txt"
    else
      restore_scale_state "$staging/scale-state-current.txt"
    fi
    ok "Workloads scaled back up."
  fi

  rm -rf "$staging"
  local rc=0; set +e; settle; rc=$?; set -e
  report_result "$rc"
  hint "Verify users, scans and historical data, then run a test scan."
}

#===============================================================================
#  Status, upgrade, reconfigure, logs
#===============================================================================

platform_url() {
  local ip
  ip="$(kubectl get svc nginx-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(kubectl get svc nginx-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  printf '%s' "$ip"
}

report_result() {
  local rc="$1"
  log "Verification"
  kubectl get pods -n "$NAMESPACE" 2>/dev/null || true
  case "$rc" in
    0) ok "Every pod is Running or Completed." ;;
    1) warn "Some pods cannot be scheduled:"
       not_ready_pods | sed 's/^/        /'
       hint "This node is short of resources. Give the VM more CPU/RAM, or re-run with --profile <values-resources-none.yaml>."
       ;;
    2) warn "Not everything was ready within ${WAIT_MINUTES} minutes. Outstanding:"
       not_ready_pods | sed 's/^/        /'
       hint "kubectl describe pod -n ${NAMESPACE} <pod> | tail -30"
       hint "kubectl logs -n ${NAMESPACE} <pod> --previous --tail=50"
       ;;
  esac

  log "Reachability"
  local code lb ip
  code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 20 "https://${PLATFORM_HOST}/" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  if [[ "$code" =~ ^(200|301|302|307|308)$ ]]; then
    ok "https://${PLATFORM_HOST}/ answered HTTP ${code}"
  else
    warn "https://${PLATFORM_HOST}/ returned '${code}'. If pods are still starting, retry shortly."
  fi
  lb="$(platform_url)"
  ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"

  cat <<EOF

${C_OK}${C_B}Done.${C_OFF}

  Release       : ${RELEASE}   namespace: ${NAMESPACE}
  Chart         : ${CHART_VERSION_ACTUAL:-unknown}
  Profile       : $( [[ -n "${RESOURCE_PROFILE:-}" ]] && basename "$RESOURCE_PROFILE" || echo 'chart defaults')
  Values        : ${VALUES_FILE}
  Warnings      : ${WARNINGS}
  Log           : ${LOGFILE:-n/a}

  Open the platform at   ${C_B}https://${PLATFORM_HOST}${C_OFF}
$( [[ -n "$lb" ]] && printf '  LoadBalancer address   %s\n' "$lb" )
$( [[ -n "$ip" ]] && printf '  This host              %s\n' "$ip" )

  From another machine, point DNS (or the local hosts file) at this host:
      ${ip:-<host-ip>}    ${PLATFORM_HOST}

  The first visit shows the registration page — create the first admin user there.
  A self-signed certificate is used unless you passed --tls-cert/--tls-key, so
  expect a browser warning.

  Useful next steps
      $SCRIPT_NAME status
      $SCRIPT_NAME backup
      kubectl get pods -n ${NAMESPACE}
EOF
}

cmd_status() {
  require_cluster
  log "Cluster"
  kubectl get nodes -o wide 2>/dev/null || true
  printf '\n'
  kubectl top nodes 2>/dev/null || info "(metrics-server not available)"

  log "Release"
  if release_exists; then
    helm status "$RELEASE" -n "$NAMESPACE" 2>/dev/null | sed -n '1,12p'
    helm history "$RELEASE" -n "$NAMESPACE" 2>/dev/null | tail -6
  else
    warn "Release '${RELEASE}' not found in namespace '${NAMESPACE}'."
  fi

  log "Workloads"
  kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || true
  local bad_pods; bad_pods="$(not_ready_pods || true)"
  if [[ -n "$bad_pods" ]]; then
    warn "Pods not ready:"; printf '%s\n' "$bad_pods" | sed 's/^/        /'
  else
    ok "All pods Running or Completed."
  fi

  log "Storage"
  kubectl get pvc -n "$NAMESPACE" 2>/dev/null || true

  log "Networking"
  kubectl get svc -n "$NAMESPACE" 2>/dev/null | head -20 || true
  local lb; lb="$(platform_url)"
  [[ -n "$lb" ]] && ok "nginx-service external address: ${lb}" || info "nginx-service has no external address yet."

  log "Recent warnings"
  kubectl get events -n "$NAMESPACE" --field-selector type=Warning \
    --sort-by=.lastTimestamp 2>/dev/null | tail -12 || true

  log "Reachability"
  local code; code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${PLATFORM_HOST}/" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  [[ "$code" =~ ^(200|301|302|307|308)$ ]] && ok "https://${PLATFORM_HOST}/ → HTTP ${code}" \
                                           || warn "https://${PLATFORM_HOST}/ → '${code}'"
}

cmd_upgrade() {
  require_cluster
  release_exists || die "Release '${RELEASE}' not found. Use 'install' first."
  collect_credentials
  registry_login
  pull_chart
  [[ -f "$VALUES_FILE" ]] || {
    warn "${VALUES_FILE} is missing; recovering the live values from the release."
    mkdir -p "$WORKDIR"
    helm get values "$RELEASE" -n "$NAMESPACE" -o yaml > "$VALUES_FILE"
    chmod 600 "$VALUES_FILE"
  }
  select_profile
  helm_value_args
  log "Upgrading ${RELEASE}"
  hint "Components are updated in place, so expect brief downtime."
  # --reset-then-reuse-values keeps your settings while adopting new chart defaults.
  run helm upgrade "$RELEASE" "$CHART_LOCAL" \
      --namespace "$NAMESPACE" \
      "${VALUE_ARGS[@]}" \
      --reset-then-reuse-values \
      --cleanup-on-fail \
      --wait --wait-for-jobs \
      --timeout "$HELM_TIMEOUT"
  ok "Upgrade applied."
  prune_unschedulable_scanners
  local rc=0; set +e; settle; rc=$?; set -e
  save_state "$rc"
  report_result "$rc"
}

cmd_reconfigure() {
  require_cluster
  release_exists || die "Release '${RELEASE}' not found. Use 'install' first."
  collect_credentials
  registry_login
  pull_chart
  select_profile
  write_values
  helm_value_args
  log "Applying configuration changes"
  run helm upgrade "$RELEASE" "$CHART_LOCAL" \
      --namespace "$NAMESPACE" "${VALUE_ARGS[@]}" \
      --cleanup-on-fail --wait --wait-for-jobs --timeout "$HELM_TIMEOUT"
  ok "Configuration applied."
  prune_unschedulable_scanners
  local rc=0; set +e; settle; rc=$?; set -e
  save_state "$rc"
  report_result "$rc"
}

cmd_logs() {
  require_cluster
  mkdir -p "$LOG_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local d; d="$(mktemp -d)"
  log "Collecting a support bundle"

  kubectl get nodes -o wide            > "$d/nodes.txt" 2>&1 || true
  kubectl describe nodes               > "$d/nodes-describe.txt" 2>&1 || true
  kubectl get all -n "$NAMESPACE" -o wide > "$d/resources.txt" 2>&1 || true
  kubectl get pvc,pv -n "$NAMESPACE"   > "$d/storage.txt" 2>&1 || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp > "$d/events.txt" 2>&1 || true
  helm status "$RELEASE" -n "$NAMESPACE"  > "$d/helm-status.txt" 2>&1 || true
  helm history "$RELEASE" -n "$NAMESPACE" > "$d/helm-history.txt" 2>&1 || true
  # Values with the secrets stripped, so the bundle is safe to send.
  helm get values "$RELEASE" -n "$NAMESPACE" -o yaml 2>/dev/null \
    | sed -E 's/(license_key|password|client_secret|privkey):.*/\1: <redacted>/' \
    > "$d/helm-values-redacted.yaml" || true

  mkdir -p "$d/pods"
  local p
  for p in $(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null); do
    local n="${p#pod/}"
    kubectl describe "$p" -n "$NAMESPACE"            > "$d/pods/${n}.describe" 2>&1 || true
    kubectl logs "$p" -n "$NAMESPACE" --tail=500     > "$d/pods/${n}.log" 2>&1 || true
    kubectl logs "$p" -n "$NAMESPACE" --previous --tail=200 > "$d/pods/${n}.prev.log" 2>&1 || true
  done

  { uname -a; echo; free -h; echo; df -h; echo; command -v helm >/dev/null && helm version; } > "$d/host.txt" 2>&1 || true
  $SUDO journalctl -u k3s --no-pager -n 500 > "$d/k3s.log" 2>&1 || true

  local out="$LOG_DIR/invicti-support-${stamp}.tar.gz"
  tar czf "$out" -C "$d" .
  chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$out" 2>/dev/null || true
  rm -rf "$d"
  ok "Support bundle: ${out}"
  info "Values were redacted, but review the pod logs before sending externally."
}

cmd_version() {
  printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
  command -v helm    >/dev/null && printf 'helm       %s\n' "$(helm version --short 2>/dev/null)"
  command -v kubectl >/dev/null && printf 'kubectl    %s\n' "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo unknown)"
  command -v k3s     >/dev/null && printf 'k3s        %s\n' "$(k3s --version 2>/dev/null | head -1)"
  if setup_kubeconfig 2>/dev/null; then
    printf 'kubernetes %s\n' "$(kubectl version -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown)"
    if release_exists; then
      printf 'release    %s\n' "$(helm list -n "$NAMESPACE" -o json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["chart"]+" ("+d[0]["status"]+")" if d else "none")' 2>/dev/null || echo unknown)"
    else
      printf 'release    not installed\n'
    fi
  fi
}

#===============================================================================
#  CLI
#===============================================================================

usage() {
cat <<EOF
${C_B}invicti-platform.sh${C_OFF} ${SCRIPT_VERSION} — Invicti Platform on-premises lifecycle manager

${C_B}USAGE${C_OFF}
  $SCRIPT_NAME <command> [options]

${C_B}COMMANDS${C_OFF}
  install       Preflight, install k3s + Helm 3 if needed, deploy the chart
  check         Run every preflight check and change nothing
  status        Health and diagnostics for an existing deployment
  upgrade       helm upgrade to the latest (or a pinned) chart version
  reconfigure   Re-render values.yaml from the flags below and apply it
  backup        Consistent backup of config, secrets and PVC data
  restore       Restore a backup produced by this script
  uninstall     Remove the release; optionally purge data and cluster scope
  logs          Collect a redacted support bundle
  version       Print component versions

${C_B}CORE OPTIONS${C_OFF}
  --email <addr>            Invicti account email        (env INVICTI_EMAIL)
  --license <key>           Invicti license key          (env INVICTI_LICENSE_KEY)
  --host <fqdn>             Platform hostname, no scheme (env PLATFORM_HOST)
  --namespace <ns>          Kubernetes namespace         (default: invicti)
  --release <name>          Helm release name            (default: invicti-platform)
  --chart-version <v>       Pin a chart version          (default: latest)
  --values <file>           Extra values file, applied last
  --profile <file>          Force a values-resources-*.yaml
  --yes                     Never prompt
  --dry-run                 Print the commands without running them
  --force                   Continue even if preflight fails
  --no-color                Plain output

${C_B}FEATURE OPTIONS${C_OFF}
  --smtp-host <h> --smtp-port <p> --smtp-user <u> --smtp-pass <p>
  --smtp-from <addr> --smtp-name <display> --smtp-security <ssl|non-ssl>
  --tls-cert <file> --tls-key <file>      Serve a real certificate
  --db-host <h> --db-port <p> --db-user <u> --db-pass <p> --db-ssl
                                          Use an external PostgreSQL 16+
  --proxy-http <url> --proxy-https <url> --no-proxy <list>
  --jira-client-id <id> --jira-client-secret <secret>
  --keda-existing                         Reuse the cluster's existing KEDA
  --service-type <LoadBalancer|NodePort|ClusterIP>   --node-port <30443>
  --openshift                             Apply the OpenShift overlay
  --registry-address <host>               Pull images from your own registry
  --registry-path <path>                  Image path in that registry (default: infrastructure)
  --registry-proxy-url <url>              Upstream proxy URL for that registry
  --two-phase                             Split into a cluster-admin prereqs release
                                          plus a namespace-scoped app release
  --scanner-min-replicas <n|default|auto> Warm DAST scanners KEDA keeps ready.
                                          Chart default is 4 (~7 Gi each).
                                          'auto' (default) fits them to the node.

${C_B}INSTALL BEHAVIOUR${C_OFF}
  --install-k3s / --no-k3s  Force or forbid installing k3s
  --expand-disk / --no-expand-disk        Reclaim unallocated LVM space
  --os-upgrade              Run apt full-upgrade first (off by default)
  --wait-minutes <n>        How long to wait for pods (default 30)
  --no-fallback             Do not retry with the 'none' resource profile

${C_B}UNINSTALL SCOPE${C_OFF}
  (default)                 Remove the Helm release only; data survives
  --purge-data              Also delete PVCs and the namespace  ${C_WARN}destroys data${C_OFF}
  --purge                   The above plus cluster-scoped leftovers (KEDA CRDs,
                            ClusterRoles, webhooks). Required before a clean
                            re-install.
  --purge-all               The above plus k3s itself

${C_B}BACKUP / RESTORE${C_OFF}
  --output <file>           Backup destination
  --from <file>             Archive to restore
  --no-pvc                  Configuration-only backup (platform stays online)

${C_B}EXAMPLES${C_OFF}
  $SCRIPT_NAME install --email you@corp.com --license XXXX --host invicti.corp.com
  $SCRIPT_NAME install --yes --smtp-host smtp.corp.com --smtp-from no-reply@corp.com \\
                --tls-cert /etc/ssl/inv.pem --tls-key /etc/ssl/inv.key
  $SCRIPT_NAME backup --output /mnt/nfs/invicti-\$(date +%F).tar.gz
  $SCRIPT_NAME restore --from /mnt/nfs/invicti-2026-08-01.tar.gz
  $SCRIPT_NAME uninstall --purge          # clean slate, keeps k3s
  $SCRIPT_NAME status

Docs: https://docs.invicti.com/ip/category/invicti-platform-on-premises
EOF
}

parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 0; }
  case "$1" in
    install|check|status|upgrade|reconfigure|backup|restore|uninstall|logs|version) COMMAND="$1"; shift ;;
    -h|--help)    usage; exit 0 ;;
    -v|--version) COMMAND="version" ;;
    *) die "Unknown command '$1'. Run '$SCRIPT_NAME --help'." ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --email)              INVICTI_EMAIL="$2"; shift 2 ;;
      --license)            INVICTI_LICENSE_KEY="$2"; shift 2 ;;
      --host)               PLATFORM_HOST="$2"; shift 2 ;;
      --namespace|-n)       NAMESPACE="$2"; shift 2 ;;
      --release)            RELEASE="$2"; shift 2 ;;
      --chart-version)      CHART_VERSION="$2"; shift 2 ;;
      --values)             EXTRA_VALUES="$2"; shift 2 ;;
      --profile)            RESOURCE_PROFILE="$2"; shift 2 ;;
      --smtp-host)          SMTP_HOST="$2"; shift 2 ;;
      --smtp-port)          SMTP_PORT="$2"; shift 2 ;;
      --smtp-user)          SMTP_USERNAME="$2"; shift 2 ;;
      --smtp-pass)          SMTP_PASSWORD="$2"; shift 2 ;;
      --smtp-from)          SMTP_MAIL="$2"; shift 2 ;;
      --smtp-name)          SMTP_DISPLAYNAME="$2"; shift 2 ;;
      --smtp-security)      SMTP_SECURITY="$2"; shift 2 ;;
      --smtp-engine)        SMTP_ENGINE="$2"; shift 2 ;;
      --tls-cert)           TLS_CERT="$2"; shift 2 ;;
      --tls-key)            TLS_KEY="$2"; shift 2 ;;
      --db-host)            DB_HOST="$2"; shift 2 ;;
      --db-port)            DB_PORT="$2"; shift 2 ;;
      --db-user)            DB_USER="$2"; shift 2 ;;
      --db-pass)            DB_PASSWORD="$2"; shift 2 ;;
      --db-cert)            DB_CERT="$2"; shift 2 ;;
      --db-ssl)             DB_SSL="true"; shift ;;
      --proxy-http)         PROXY_HTTP="$2"; shift 2 ;;
      --proxy-https)        PROXY_HTTPS="$2"; shift 2 ;;
      --no-proxy)           PROXY_NOPROXY="$2"; shift 2 ;;
      --jira-client-id)     JIRA_CLIENT_ID="$2"; shift 2 ;;
      --jira-client-secret) JIRA_CLIENT_SECRET="$2"; shift 2 ;;
      --keda-existing)      KEDA_EXISTING="true"; shift ;;
      --service-type)       SERVICE_TYPE="$2"; shift 2 ;;
      --node-port)          NODE_PORT="$2"; shift 2 ;;
      --openshift)          OPENSHIFT="true"; shift ;;
      --registry-address)   REGISTRY_ADDRESS="$2"; shift 2 ;;
      --registry-path)      REGISTRY_PATH="$2"; shift 2 ;;
      --registry-proxy-url) REGISTRY_PROXY_URL="$2"; shift 2 ;;
      --two-phase)          TWO_PHASE="true"; shift ;;
      --scanner-min-replicas) SCANNER_MIN_REPLICAS="$2"; shift 2 ;;
      --install-k3s)        INSTALL_K3S="yes"; shift ;;
      --no-k3s)             INSTALL_K3S="no"; shift ;;
      --expand-disk)        EXPAND_DISK="yes"; shift ;;
      --no-expand-disk)     EXPAND_DISK="no"; shift ;;
      --os-upgrade)         SKIP_UPGRADE="false"; shift ;;
      --wait-minutes)       WAIT_MINUTES="$2"; shift 2 ;;
      --no-fallback)        AUTO_FALLBACK="false"; shift ;;
      --helm-version)       HELM_VERSION="$2"; shift 2 ;;
      --purge-data)         PURGE_DATA="true"; shift ;;
      --purge)              PURGE_DATA="true"; PURGE_CLUSTER="true"; shift ;;
      --purge-all)          PURGE_DATA="true"; PURGE_CLUSTER="true"; PURGE_K3S="true"; shift ;;
      --output)             BACKUP_FILE="$2"; shift 2 ;;
      --from)               RESTORE_FILE="$2"; shift 2 ;;
      --no-pvc)             INCLUDE_PVC="false"; shift ;;
      --helper-image)       HELPER_IMAGE="$2"; shift 2 ;;
      --yes|-y)             ASSUME_YES="true"; shift ;;
      --dry-run)            DRY_RUN="true"; shift ;;
      --force)              FORCE="true"; shift ;;
      --no-color)           NO_COLOR="true"; shift ;;
      -h|--help)            usage; exit 0 ;;
      *) die "Unknown option '$1'. Run '$SCRIPT_NAME --help'." ;;
    esac
  done

  # Validation that is cheap to do now and expensive to discover later.
  [[ "$PLATFORM_HOST" =~ ^https?:// ]] && die "--host must be a bare hostname, without https://"
  if [[ -n "$TLS_CERT$TLS_KEY" ]]; then
    [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]] || die "--tls-cert and --tls-key must be given together."
    [[ -r "$TLS_CERT" ]] || die "Cannot read certificate: $TLS_CERT"
    [[ -r "$TLS_KEY"  ]] || die "Cannot read private key: $TLS_KEY"
  fi
  [[ -n "$EXTRA_VALUES" && ! -r "$EXTRA_VALUES" ]] && die "Cannot read values file: $EXTRA_VALUES"
  if [[ -n "$SERVICE_TYPE" && ! "$SERVICE_TYPE" =~ ^(LoadBalancer|NodePort|ClusterIP)$ ]]; then
    die "--service-type must be LoadBalancer, NodePort or ClusterIP."
  fi
}

main() {
  parse_args "$@"
  case "$COMMAND" in
    version) cmd_version || true; exit 0 ;;
  esac
  start_log
  banner
  case "$COMMAND" in
    install)     cmd_install ;;
    check)       preflight; log "Check complete — nothing was changed."; exit $(( FAILURES > 0 ? 1 : 0 )) ;;
    status)      cmd_status ;;
    upgrade)     cmd_upgrade ;;
    reconfigure) cmd_reconfigure ;;
    backup)      cmd_backup ;;
    restore)     cmd_restore ;;
    uninstall)   cmd_uninstall ;;
    logs)        cmd_logs ;;
  esac
}

main "$@"
