#!/bin/sh
#
# stop-macos-sandbox.sh — stop the macOS sandbox VM and its host bridges.
#
# Usage:
#   ./scripts/stop-macos-sandbox.sh
#
# What it does:
#   1. Stops the working VM with 'tart stop': a graceful shutdown of the
#      guest (tart waits up to 30 s), force-terminated by tart when the
#      guest hangs.
#   2. Kills the host socat bridges that run-macos-sandbox.sh started for
#      this run — the SSH agent listener on $SANDBOX_AGENT_PORT and the
#      Docker engine listener on $SANDBOX_DOCKER_PORT. They outlive the VM
#      by design (the VM needs them while it runs), so a bare 'tart stop'
#      would leave them up; only socat processes are killed, an unrelated
#      listener on the same port is left alone. The guest-side bridges
#      (inside the guest) stop with the VM.
#
# Idempotent: safe to run when the sandbox is already stopped.
#
# Environment (defaults in parentheses):
#   SANDBOX_VM              working VM name (sandbox-macos)
#   SANDBOX_AGENT_PORT      TCP port for the SSH agent bridge (4100)
#   SANDBOX_DOCKER_PORT     TCP port for the Docker engine bridge (4101)
#   NO_COLOR                disable colored output (any non-empty value)
#
# Requires tart (brew install cirruslabs/cli/tart); lsof (ships with macOS)
# is needed only when a host bridge listener must be stopped.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- configuration ----------------------------------------------------------

vm=${SANDBOX_VM:-sandbox-macos}
agent_port=${SANDBOX_AGENT_PORT:-4100}
docker_port=${SANDBOX_DOCKER_PORT:-4101}

# Shared helpers (colors, die, warn, ...) and VM helpers (vm_exists,
# vm_state) — also used by the run script; keep the logic in the lib, not
# here.
. "$repo_root/scripts/lib/macos-settings.sh"

# --- helpers ----------------------------------------------------------------

# Kills the host socat listener on the given TCP port (the bridge side the
# runner leaves in place). Only socat processes are touched — a listener on
# the port that this sandbox did not start is left alone and reported.
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
Usage: stop-macos-sandbox.sh [options]

Stops the macOS sandbox VM ('tart stop', graceful with a force fallback) and
kills the host SSH agent / Docker bridge listeners that run-macos-sandbox.sh
left up.

Options:
  -h, --help     Show this help

Environment:
  SANDBOX_VM              working VM name (sandbox-macos)
  SANDBOX_AGENT_PORT      TCP port for the SSH agent bridge (4100)
  SANDBOX_DOCKER_PORT     TCP port for the Docker engine bridge (4101)
  NO_COLOR                disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

command -v tart >/dev/null 2>&1 ||
    die "tart is not installed — run 'brew install cirruslabs/cli/tart' first."

title "Stopping macOS sandbox: $vm"

# 1. Stop the VM.
if ! vm_exists "$vm"; then
    warn "VM '$vm' does not exist (was it deleted?) — skipping 'tart stop'."
elif [ "$(vm_state "$vm")" = running ]; then
    cmd "tart stop $vm"
    tart stop "$vm" || warn "'tart stop $vm' failed — the VM may already be stopping."
    n=0
    printf '%s' "    Waiting for '$vm' to stop"
    while [ "$(vm_state "$vm")" = running ] && [ "$n" -lt 60 ]; do
        printf '.'
        sleep 2
        n=$((n + 1))
    done
    if [ "$(vm_state "$vm")" = running ]; then
        printf ' %s\n' "${c_yellow}failed${c_reset}"
        warn "'$vm' is still running — force it with 'tart stop $vm --timeout 1'."
    else
        printf ' %s\n' "${c_green}stopped${c_reset}"
        ok "VM '$vm' is stopped."
    fi
else
    info "VM '$vm' is already stopped."
fi

# 2. Kill the host bridges (SSH agent + Docker engine listeners).
step "Host bridges (SSH agent, Docker)"
stop_bridge "$agent_port"
stop_bridge "$docker_port"

# --- summary ----------------------------------------------------------------

state=$(vm_state "$vm")
[ -n "$state" ] || state='stopped'
step "Sandbox stopped"
printf '    %-12s %s\n' 'VM:' "${c_bold}$vm${c_reset} ($state)"
printf '    %-12s %s\n' 'Bridges:' "host listeners on TCP $agent_port and $docker_port stopped"
