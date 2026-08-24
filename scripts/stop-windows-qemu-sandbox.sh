#!/bin/bash
#
# stop-windows-qemu-sandbox.sh — stop the Windows 11 (ARM64) sandbox VM and
# its host bridges.
#
# Usage:
#   ./scripts/stop-windows-qemu-sandbox.sh
#
# What it does:
#   1. Stops qemu-system-aarch64 via the pid file the runner writes
#      ($SANDBOX_STATE_DIR/qemu.pid) and waits until the process is gone.
#      When the pid file is missing or stale, falls back to matching qemu
#      processes whose command line references the state dir (the overlay
#      path is unique to this sandbox), so a VM started by the runner is
#      always found.
#   2. Stops swtpm ($SANDBOX_STATE_DIR/swtpm.pid) — it otherwise holds the
#      TPM state lock and blocks the next run.
#   3. Kills the host socat bridges that run-windows-qemu-sandbox.sh
#      started on $SANDBOX_AGENT_PORT and $SANDBOX_DOCKER_PORT (SSH agent
#      + Docker engine listeners). Only socat processes are touched.
#   4. Removes the stale qemu/swtpm pid files and the swtpm socket, so the
#      state is clean for the next run.
#
# Idempotent: safe to run when the sandbox is already stopped.
#
# Environment (defaults in parentheses):
#   SANDBOX_STATE_DIR      working VM state dir
#                          (~/Library/Application Support/agent-sandbox/windows-11-arm64-qemu)
#   SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4200)
#   SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4201)
#   NO_COLOR               disable colored output (any non-empty value)
#
# Requires: lsof, ps and pgrep (all ship with macOS).

set -euo pipefail

# --- configuration ----------------------------------------------------------

host_state_dir="${SANDBOX_STATE_DIR:-$HOME/Library/Application Support/agent-sandbox/windows-11-arm64-qemu}"
agent_port=${SANDBOX_AGENT_PORT:-4200}
docker_port=${SANDBOX_DOCKER_PORT:-4201}
qemu_pidfile="$host_state_dir/qemu.pid"
swtpm_pidfile="$host_state_dir/swtpm.pid"
swtpm_sock="$host_state_dir/swtpm.sock"

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

# Sends SIGTERM to $pid and waits up to 30 s for it to exit. Returns 0 when
# the process is gone, 1 when it survived.
kill_wait() {
    name="$1"
    pid="$2"
    if ! kill -0 "$pid" 2>/dev/null; then
        info "$name is already stopped (pid $pid is not running)."
        return 0
    fi
    cmd "kill $pid"
    kill "$pid" 2>/dev/null || true
    n=0
    printf '%s' "    Waiting for $name to stop"
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 30 ]; do
        printf '.'
        sleep 1
        n=$((n + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        printf ' %s\n' "${c_yellow}failed${c_reset}"
        warn "$name (pid $pid) did not stop after 30 s — kill it manually" \
            "with: kill -9 $pid"
        return 1
    fi
    printf ' %s\n' "${c_green}stopped${c_reset}"
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

# Finds a runner-launched qemu when the pidfile is missing or stale: the
# overlay path in the command line (the state dir) is unique to this
# sandbox, so a qemu for another SANDBOX_STATE_DIR is never matched.
find_qemu_pids() {
    pgrep -f "qemu-system-aarch64.*$host_state_dir" 2>/dev/null || true
}

stop_qemu() {
    if [ -f "$qemu_pidfile" ]; then
        pid=$(cat "$qemu_pidfile" | tr -d ' ')
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill_wait qemu "$pid" || return 1
            rm -f "$qemu_pidfile"
            return 0
        fi
        if [ -n "$pid" ]; then
            info "qemu (pid $pid) is not running — removing the stale pidfile."
        fi
        rm -f "$qemu_pidfile"
    fi
    pids=$(find_qemu_pids)
    if [ -z "$pids" ]; then
        info "qemu is not running — nothing to stop."
        return 0
    fi
    warn "A sandbox qemu is running (pid(s): $pids) with no pidfile — stopping it."
    for pid in $pids; do
        kill_wait qemu "$pid" || true
    done
    return 0
}

stop_swtpm() {
    if [ -f "$swtpm_pidfile" ]; then
        pid=$(cat "$swtpm_pidfile" | tr -d ' ')
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill_wait swtpm "$pid" || return 1
        elif [ -n "$pid" ]; then
            info "swtpm (pid $pid) is not running — removing the stale pidfile."
        else
            info "No swtpm pidfile ($swtpm_pidfile) — nothing to stop."
        fi
    else
        info "No swtpm pidfile ($swtpm_pidfile) — nothing to stop."
    fi
    rm -f "$swtpm_pidfile" "$swtpm_sock"
    return 0
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: stop-windows-qemu-sandbox.sh [options]

Stops the Windows 11 (ARM64) sandbox VM: qemu (via the runner's qemu.pid,
with a command-line fallback), swtpm, and the host SSH agent / Docker
bridge listeners that run-windows-qemu-sandbox.sh left up.

Options:
  -h, --help     Show this help

Environment:
  SANDBOX_STATE_DIR      working VM state dir
  SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4200)
  SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4201)
  NO_COLOR               disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

title "Stopping Windows QEMU sandbox"

# 1. qemu (the VM itself).
step "Stopping qemu"
stop_qemu || true

# 2. swtpm (holds the TPM state lock).
step "Stopping swtpm"
stop_swtpm || true

# 3. Host bridges (SSH agent + Docker engine listeners).
step "Host bridges (SSH agent, Docker)"
stop_bridge "$agent_port"
stop_bridge "$docker_port"

step "Sandbox stopped"
