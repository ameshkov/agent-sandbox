#!/bin/sh
#
# sync-macos-sandbox.sh — copy the host's user settings into the sandbox
# guest on demand.
#
# Usage:
#   ./scripts/sync-macos-sandbox.sh [--yes]
#
# run-macos-sandbox.sh offers to copy the host's user settings into the guest
# once per VM (tracked by a versioned marker inside the guest). This script
# does the same copy on demand — no VM restart needed — and updates the
# marker, so the next run of run-macos-sandbox.sh sees the guest as up to
# date. After the copy, OpenChamber is restarted so the new settings take
# effect.
#
# What it copies (the same set as run-macos-sandbox.sh, see docs/macos.md):
#   the global opencode config (json, tui, agents, commands, modes, plugins,
#   skills, tools, themes) + auth, the OpenCodeReview config
#   (~/.opencodereview/config.json), the Copilot CLI config + skills
#   (~/.copilot/config.json, ~/.copilot/skills/), the VS Code extensions
#   (~/.vscode/extensions) and user config (settings.json, keybindings.json,
#   snippets/), ~/.ssh/allowed_signers, ~/.ssh/known_hosts, ~/.ssh/*.sh and
#   ~/.gitconfig
#
# The VM must be running — 'tart exec' only works while the guest is up.
# Start it with run-macos-sandbox.sh first if it is stopped.
#
# Environment (defaults in parentheses):
#   SANDBOX_VM    working VM name (sandbox-macos)
#   NO_COLOR      disable colored output (any non-empty value)
#
# Requires tart (brew install cirruslabs/cli/tart).

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Shared helpers + user-settings logic (same code run-macos-sandbox.sh uses).
. "$repo_root/scripts/lib/macos-settings.sh"

vm=${SANDBOX_VM:-sandbox-macos}
yes=0

usage() {
    cat <<'EOF'
Usage: sync-macos-sandbox.sh [options]

Copies the host's user settings into the sandbox guest on demand: the global
opencode config (json, tui, agents, commands, modes, plugins, skills, tools,
themes) + auth, the OpenCodeReview config (~/.opencodereview/config.json),
the Copilot CLI config + skills (~/.copilot/config.json,
~/.copilot/skills/), the VS Code extensions (~/.vscode/extensions) and user
config (settings.json, keybindings.json, snippets/), ~/.ssh/allowed_signers,
~/.ssh/known_hosts, ~/.ssh/*.sh and ~/.gitconfig (see docs/macos.md). The VM
must be running.
Updates the guest's settings marker, so run-macos-sandbox.sh won't re-offer
the copy, and restarts OpenChamber so the new settings take effect.

Options:
  --yes, -y  Copy without asking for confirmation
  -h, --help Show this help

Environment:
  SANDBOX_VM    working VM name (sandbox-macos)
  NO_COLOR      disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes | -y) yes=1 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done

command -v tart >/dev/null 2>&1 ||
    die "tart is not installed — run 'brew install cirruslabs/cli/tart' first."

title "Syncing user settings into $vm"

# The copy goes over 'tart exec', which needs a running guest.
if ! vm_exists "$vm"; then
    die "working VM '$vm' not found — run ./scripts/run-macos-sandbox.sh first."
fi
if [ "$(vm_state "$vm")" != running ]; then
    die "VM '$vm' is not running — start it with ./scripts/run-macos-sandbox.sh first."
fi

settings_list=$(collect_settings_files)
if [ -z "$settings_list" ]; then
    info "No user settings found on the host (opencode config and auth, OpenCodeReview config, Copilot config, VS Code config and extensions, ~/.ssh, ~/.gitconfig) — nothing to copy."
    exit 0
fi

info "Found on the host — will copy into the guest's home directory:"
printf '%s\n' "$settings_list" | while IFS= read -r f; do
    info "  $HOME/$f"
done
if [ "$yes" != 1 ] && ! confirm "Copy these user settings into the guest?" y; then
    info "Skipped — re-run the script to copy them later."
    exit 0
fi

if ! printf '%s\n' "$settings_list" | copy_settings_to_guest; then
    die "settings sync failed — see the warnings above."
fi

count=$(printf '%s\n' "$settings_list" | wc -l | tr -d ' ')
ok "Copied $count item(s) into the guest (version $settings_version)."

# OpenChamber runs the opencode CLI under the hood, so it holds the settings
# it started with — restart it so the fresh copy takes effect.
if restart_openchamber; then
    ok "Done — settings synced into '$vm'."
else
    warn "Settings are in the guest, but OpenChamber could not be restarted —"
    warn "run 'openchamber restart' inside the guest, or re-run this script."
fi
