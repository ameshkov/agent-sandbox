#!/bin/bash
#
# stop-windows-vmware-sandbox.sh — stop the Windows 11 (ARM64) VMware
# sandbox VM and its host bridges.
#
# Usage:
#   ./scripts/stop-windows-vmware-sandbox.sh
#
# What it does:
#   1. Stops the working VM with 'vmrun -T fusion stop' — a graceful
#      shutdown via VMware Tools ('soft'), falling back to a hard power off
#      when the guest does not stop within a minute. Waits until 'vmrun
#      list' no longer shows the VM.
#   2. Kills the host socat bridges that run-windows-vmware-sandbox.sh
#      started on $SANDBOX_AGENT_PORT and $SANDBOX_DOCKER_PORT (SSH agent
#      + Docker engine listeners). Only socat processes are touched. The
#      guest-side bridges stop with the VM.
#
# Idempotent: safe to run when the sandbox is already stopped.
#
# Environment (defaults in parentheses):
#   SANDBOX_STATE_DIR      working VM state dir
#                          (~/Library/Application Support/agent-sandbox/windows-11-arm64-vmware)
#   SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4300)
#   SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4301)
#   NO_COLOR               disable colored output (any non-empty value)
#
# Requires VMware Fusion (vmrun, resolved by scripts/lib/windows-vmware/
# lib.sh — PATH > Fusion app bundle, or FUSION_APP_PATH); lsof and ps ship
# with macOS and are needed only when a host bridge listener must be
# stopped.

set -euo pipefail

# --- configuration ----------------------------------------------------------

host_state_dir="${SANDBOX_STATE_DIR:-$HOME/Library/Application Support/agent-sandbox/windows-11-arm64-vmware}"
agent_port=${SANDBOX_AGENT_PORT:-4300}
docker_port=${SANDBOX_DOCKER_PORT:-4301}

# Deterministic state-dir paths, same as the runner's.
work_vmx="$host_state_dir/working/sandbox-windows-11-vmware.vmx"

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- shared library ---------------------------------------------------------
#
# scripts/lib/windows-vmware/lib.sh: vmrun resolution (PATH > Fusion app
# bundle) and the vmrun() wrapper.

library_dir="$repo_root/scripts/lib/windows-vmware"
# shellcheck source=scripts/lib/windows-vmware/lib.sh
source "$library_dir/lib.sh"

# --- output helpers (same conventions as the macOS runner) ------------------

c_bold=''; c_dim=''; c_green=''; c_yellow=''; c_blue=''; c_reset=''
ce_bold=''; ce_red=''; ce_yellow=''; ce_reset=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$(printf '\033[1m'); c_dim=$(printf '\033[2m')
    c_green=$(printf '\033[32m'); c_yellow=$(printf '\033[33m')
    c_blue=$(printf '\033[34m'); c_reset=$(printf '\033[0m')
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

# --- helpers ----------------------------------------------------------------

# Returns the VM path when the working VM is running (per 'vmrun list'), or
# nothing.
running_work_vmx() {
    if [ -f "$work_vmx" ] && vmrun list 2>/dev/null | grep -q "$work_vmx"; then
        printf '%s\n' "$work_vmx"
    fi
}

# Stops the VM: graceful first ('soft' via VMware Tools), hard power off as
# a fallback after a minutes' wait.
stop_work_vm() {
    vm_path=$(running_work_vmx)
    if [ -z "$vm_path" ]; then
        if [ -f "$work_vmx" ]; then
            info "VM is already stopped."
        else
            warn "No working VM ($work_vmx) — was the sandbox ever run?"
        fi
        return 0
    fi

    cmd "vmrun -T fusion stop $work_vmx soft"
    vmrun stop "$work_vmx" soft 2>/dev/null || true
    n=0
    printf '%s' "    Waiting for a graceful shutdown (up to 1 min)"
    while [ -n "$(running_work_vmx)" ] && [ "$n" -lt 30 ]; do
        printf '.'
        sleep 2
        n=$((n + 1))
    done
    if [ -n "$(running_work_vmx)" ]; then
        printf ' %s\n' "${c_yellow}graceful shutdown timed out${c_reset}"
        info "The guest did not stop gracefully — powering it off."
        cmd "vmrun -T fusion stop $work_vmx"
        vmrun stop "$work_vmx" || true
        n=0
        while [ -n "$(running_work_vmx)" ] && [ "$n" -lt 30 ]; do
            sleep 2
            n=$((n + 1))
        done
        if [ -n "$(running_work_vmx)" ]; then
            warn "The VM is still running — stop it manually with" \
                "'vmrun -T fusion stop' and check the Fusion window."
            return 1
        fi
    fi
    printf ' %s\n' "${c_green}stopped${c_reset}"
    ok "VM is stopped ($work_vmx)."
    return 0
}

# Kills the host socat listener on the given TCP port. Only socat
# processes are touched — a listener this sandbox did not start is left
# alone and reported.
stop_bridge() {
    port="$1"
    pids=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [ -z "$pids" ]; then
        info "No listener on TCP port $port — nothing to stop."
        return 0
    fi
    for pid in $pids; do
        if [ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" = socat ]; then
            cmd "kill $pid"
            kill "$pid" 2>/dev/null || true
            ok "Stopped the host bridge on TCP $port (pid $pid)."
        else
            warn "Listener on TCP $port (pid $pid) is not a socat process" \
                "— leaving it alone."
        fi
    done
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: stop-windows-vmware-sandbox.sh [options]

Stops the Windows 11 (ARM64) VMware sandbox VM (vmrun stop, graceful with a
hard power-off fallback) and kills the host SSH agent / Docker bridge
listeners that run-windows-vmware-sandbox.sh left up.

Options:
  -h, --help     Show this help

Environment:
  SANDBOX_STATE_DIR      working VM state dir
  SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4300)
  SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4301)
  NO_COLOR               disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$vmrun_bin" ] ||
    die "vmrun not found — install VMware Fusion (free for personal use) or set FUSION_APP_PATH."

title "Stopping Windows VMware sandbox"

# 1. The working VM.
step "Stopping the VM"
stop_work_vm || true

# 2. Host bridges (SSH agent + Docker engine listeners).
step "Host bridges (SSH agent, Docker)"
stop_bridge "$agent_port"
stop_bridge "$docker_port"

step "Sandbox stopped"
