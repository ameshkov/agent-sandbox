#!/bin/bash
#
# delete-ubuntu-vmware-sandbox.sh — delete the Ubuntu 24.04 (ARM64) VMware
# sandbox state from the host.
#
# Usage:
#   ./scripts/delete-ubuntu-vmware-sandbox.sh [--yes]
#
# What it does:
#   1. Stops the working VM and the host bridges by delegating to
#      stop-ubuntu-vmware-sandbox.sh ('vmrun stop' + the socat bridge
#      listeners the runner left up) — a delete must never race a running
#      VM, the working disk is locked while it runs.
#   2. Removes $SANDBOX_STATE_DIR recursively: the extracted pristine base
#      and the working clone, plus the pulled image cache. The next
#      run-ubuntu-vmware-sandbox.sh re-pulls the archive and re-clones.
#   3. Reports the freed disk space.
#
# Idempotent: safe to run when the sandbox is already stopped or deleted.
#
# Note: the working clone is registered with Fusion's VM library. After the
# state dir is gone, Fusion may still list the (now missing) VM — remove
# the stale entry in the Fusion UI or it disappears after a library refresh;
# it is harmless.
#
# Environment (defaults in parentheses):
#   SANDBOX_STATE_DIR      working VM state dir
#                          (~/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware)
#   SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4400)
#   SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4401)
#   NO_COLOR               disable colored output (any non-empty value)
#
# SANDBOX_AGENT_PORT / SANDBOX_DOCKER_PORT are not used here directly —
# they are honored by the stop script this one delegates to.
#
# Requires VMware Fusion (vmrun, resolved by scripts/lib/vmware.sh — PATH >
# Fusion app bundle, or FUSION_APP_PATH); lsof and ps ship with macOS and
# are needed only when a host bridge listener must be stopped.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- configuration ----------------------------------------------------------

host_state_dir="${SANDBOX_STATE_DIR:-$HOME/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware}"

yes_flag=0

# --- output helpers (same conventions as the runner) ------------------------

c_bold=''; c_dim=''; c_green=''; c_blue=''; c_reset=''
ce_bold=''; ce_red=''; ce_yellow=''; ce_reset=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$(printf '\033[1m'); c_dim=$(printf '\033[2m')
    c_green=$(printf '\033[32m'); c_blue=$(printf '\033[34m')
    c_reset=$(printf '\033[0m')
fi
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    ce_bold=$(printf '\033[1m'); ce_red=$(printf '\033[31m')
    ce_yellow=$(printf '\033[33m'); ce_reset=$(printf '\033[0m')
fi

die() { printf '%s\n' "${ce_bold}${ce_red}$(basename "$0"): $*${ce_reset}" >&2; exit 1; }
warn() { printf '%s\n' "${ce_bold}${ce_yellow}$(basename "$0"): warning: $*${ce_reset}" >&2; }
title() { printf '%s\n' "${c_bold}$*${c_reset}"; }
step()  { printf '%s\n' "${c_bold}${c_blue}==> $*${c_reset}"; }
info()  { printf '%s\n' "    $*"; }
cmd()   { printf '%s\n' "${c_dim}    $*${c_reset}"; }
ok()    { printf '%s\n' "${c_green}    $*${c_reset}"; }

# $1 prompt, $2 default (y or n); returns 0 if the user answered yes.
confirm() {
    prompt="$1"
    default="${2:-n}"
    if [ "$default" = y ]; then hint='Y/n'; else hint='y/N'; fi
    printf '%s%s%s [%s] ' "${c_bold}" "$prompt" "${c_reset}" "$hint"
    if [ ! -t 0 ]; then printf '\n'; fi
    answer=
    IFS= read -r answer || return 1
    case "$answer" in
        y | Y | yes | YES) return 0 ;;
        '') [ "$default" = y ] && return 0; return 1 ;;
    esac
    return 1
}

# --yes skips every confirmation; otherwise ask.
confirm_delete() {
    if [ "$yes_flag" = 1 ]; then
        return 0
    fi
    confirm "$1" "${2:-n}"
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: delete-ubuntu-vmware-sandbox.sh [options]

Deletes the Ubuntu 24.04 (ARM64) VMware sandbox state: stops the working
VM (delegating to stop-ubuntu-vmware-sandbox.sh), then removes the state
dir (extracted pristine base + working clone + pulled image cache). The
next run-ubuntu-vmware-sandbox.sh re-pulls the archive and re-clones.

Options:
  --yes        Skip the confirmation prompt
  -h, --help   Show this help

Environment:
  SANDBOX_STATE_DIR      working VM state dir
  SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4400)
  SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4401)
  NO_COLOR               disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes) yes_flag=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

title "Deleting Ubuntu VMware sandbox"

# 1. Stop the sandbox (working VM + host bridges). The stop script is
#    idempotent, so it is safe when the VM is already stopped; its non-zero
#    exits are warnings here — the deletion is what matters.
step "Stopping the sandbox"
"$repo_root/scripts/stop-ubuntu-vmware-sandbox.sh" || true

# 2. Remove the state dir (pristine base + working clone + image cache).
step "Deleting the state"
if [ ! -e "$host_state_dir" ]; then
    info "No state at $host_state_dir (already deleted?) — nothing to delete."
else
    size=$(du -sh "$host_state_dir" 2>/dev/null | awk '{print $1}' || true)
    if confirm_delete \
        "Delete the sandbox state at '$host_state_dir' (${size:-~15 GB}; re-pulled on the next run)?" y; then
        cmd "rm -rf $host_state_dir"
        rm -rf "$host_state_dir"
        ok "State deleted: $host_state_dir (${size:-size unknown} freed)."
        warn "Fusion's VM library may still list the deleted working VM — remove the stale entry in the Fusion UI (harmless)."
    else
        info "Kept '$host_state_dir' — nothing was deleted."
    fi
fi

# --- summary ----------------------------------------------------------------

step "Sandbox deleted"
info "State: $host_state_dir"
info "Next run: ./scripts/run-ubuntu-vmware-sandbox.sh (re-pulls the archive)"
