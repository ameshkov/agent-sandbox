#!/bin/sh
#
# delete-macos-sandbox.sh — delete the macOS sandbox VM (and optionally the
# pristine image) from the Tart VM store.
#
# Usage:
#   ./scripts/delete-macos-sandbox.sh [--yes] [--pristine]
#
# What it does:
#   1. Stops the working VM and the host bridges by delegating to
#      stop-macos-sandbox.sh ('tart stop' + the socat bridge listeners the
#      runner left up) — a delete must never race a running VM.
#   2. Deletes the working VM with 'tart delete', disk included. All guest
#      state lives in the working VM (auto-logon, settings marker, OpenChamber
#      tasks), so this is the "start over" command: the next run re-clones
#      the working VM from the pristine image.
#   3. With --pristine (or --yes), also deletes the pristine image VM — the
#      ~50 GB base image; the next run re-pulls it from GHCR.
#
# Idempotent: safe to run when the sandbox is already stopped or deleted.
#
# Environment (defaults in parentheses):
#   SANDBOX_VM              working VM name (sandbox-macos)
#   SANDBOX_IMAGE           pristine image VM name (sandbox-macos-tahoe)
#   SANDBOX_AGENT_PORT      TCP port for the SSH agent bridge (4100)
#   SANDBOX_DOCKER_PORT     TCP port for the Docker engine bridge (4101)
#   NO_COLOR                disable colored output (any non-empty value)
#
# SANDBOX_AGENT_PORT / SANDBOX_DOCKER_PORT are not used here directly —
# they are honored by the stop script this one delegates to.
#
# Requires tart (brew install cirruslabs/cli/tart).

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- configuration ----------------------------------------------------------

vm=${SANDBOX_VM:-sandbox-macos}
image=${SANDBOX_IMAGE:-sandbox-macos-tahoe}

yes_flag=0
pristine_flag=0

# Shared helpers (colors, die, warn, ...) and VM helpers (vm_exists,
# vm_state) — same library as the run and stop scripts.
. "$repo_root/scripts/lib/macos-settings.sh"

# --- helpers ----------------------------------------------------------------

# --yes skips every confirmation; otherwise ask (with the same prompt style
# as the rest of the repo).
confirm_delete() {
    if [ "$yes_flag" = 1 ]; then
        return 0
    fi
    confirm "$1" "${2:-n}"
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: delete-macos-sandbox.sh [options]

Deletes the macOS sandbox VM: stops it (delegating to
stop-macos-sandbox.sh), then 'tart delete' of the working VM — the next
run-macos-sandbox.sh re-clones it from the pristine image.

Options:
  --yes        Skip all confirmation prompts
  --pristine   Also delete the pristine image VM (re-pulled on next run)
  -h, --help   Show this help

Environment:
  SANDBOX_VM              working VM name (sandbox-macos)
  SANDBOX_IMAGE           pristine image VM name (sandbox-macos-tahoe)
  SANDBOX_AGENT_PORT      TCP port for the SSH agent bridge (4100)
  SANDBOX_DOCKER_PORT     TCP port for the Docker engine bridge (4101)
  NO_COLOR                disable colored output

(The agent/docker ports are not used here directly — they are honored by
the stop script this script delegates to.)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes) yes_flag=1 ;;
        --pristine) pristine_flag=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

command -v tart >/dev/null 2>&1 ||
    die "tart is not installed — run 'brew install cirruslabs/cli/tart' first."

title "Deleting macOS sandbox: $vm"

# 1. Stop the sandbox (VM + host bridges). The stop script is idempotent, so
#    it is safe when the VM is already stopped; its non-zero exits are
#    warnings here — the deletion is what matters.
step "Stopping the sandbox"
"$repo_root/scripts/stop-macos-sandbox.sh" || true

# 2. Delete the working VM. Confirmed (--yes skips), since this destroys the
#    guest's accumulated state.
step "Deleting the working VM"
if vm_exists "$vm"; then
    if confirm_delete "Delete the working VM '$vm'? This stops and removes it — \
the next run re-clones it from '$image'." y; then
        cmd "tart delete $vm"
        if tart delete "$vm"; then
            [ -n "$(vm_state "$vm")" ] && warn "VM '$vm' still exists after 'tart delete'."
            ok "Working VM '$vm' deleted."
        else
            warn "'tart delete $vm' failed — is it running?"
        fi
    else
        info "Kept '$vm' — nothing was deleted."
    fi
else
    info "Working VM '$vm' does not exist (already deleted?) — nothing to delete."
fi

# 3. Optionally delete the pristine image. Never implied: a fresh ~50 GB pull
#    on the next run, so it is opt-in (--pristine, or the confirmation).
if [ "$pristine_flag" = 0 ] && ! confirm_delete \
    "Also delete the pristine image '$image' (frees ~50 GB; re-pulled from GHCR on the next run)?" n; then
    info "Kept the pristine image '$image'."
else
    if vm_exists "$image"; then
        # The pristine image should never run (the working VM is a clone),
        # but stop it first in case it does — tart refuses to delete a
        # running VM.
        if [ "$(vm_state "$image")" = running ]; then
            cmd "tart stop $image"
            tart stop "$image" || warn "'tart stop $image' failed — trying to delete anyway."
        fi
        cmd "tart delete $image"
        if tart delete "$image"; then
            ok "Pristine image '$image' deleted."
        else
            warn "'tart delete $image' failed — is it running?"
        fi
    else
        info "Pristine image '$image' does not exist — nothing to delete."
    fi
fi

# --- summary ----------------------------------------------------------------

step "Sandbox deleted"
info "Working VM: $vm — deleted if it existed (next run re-clones from '$image')."
info "Pristine image: $image — kept or deleted per the flags above."
info "Next run: ./scripts/run-macos-sandbox.sh"
