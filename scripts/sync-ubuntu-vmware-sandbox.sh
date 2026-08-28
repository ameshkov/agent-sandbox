#!/bin/bash
#
# sync-ubuntu-vmware-sandbox.sh — copy the host's user settings into the
# Ubuntu sandbox guest on demand (the Linux counterpart of
# scripts/sync-macos-sandbox.sh).
#
# Usage:
#   ./scripts/sync-ubuntu-vmware-sandbox.sh [--yes]
#
# run-ubuntu-vmware-sandbox.sh offers to copy the host's user settings into
# the guest once per VM (tracked by a versioned marker inside the guest).
# This script does the same copy on demand — no VM restart needed — and
# updates the marker, so the next run of run-ubuntu-vmware-sandbox.sh sees
# the guest as up to date. After the copy, OpenChamber is restarted so the
# new settings take effect.
#
# What it copies (the same set as run-ubuntu-vmware-sandbox.sh, see
# docs/ubuntu-vmware.md): the global opencode config (json, tui, agents,
# commands, modes, plugins, skills, tools, themes) + auth, the OpenCodeReview
# config (~/.opencodereview/config.json), the Copilot CLI config + skills
# (~/.copilot/config.json, ~/.copilot/skills/), the VS Code extensions
# (~/.vscode/extensions) and user config (settings.json, keybindings.json,
# snippets/), the mcp-compress-router settings, ~/.ssh/allowed_signers,
# ~/.ssh/known_hosts, ~/.ssh/*.sh and ~/.gitconfig.
#
# The VM must be running and SSH must answer — start it with
# run-ubuntu-vmware-sandbox.sh first if it is stopped.
#
# Environment (defaults in parentheses):
#   SANDBOX_STATE_DIR   working VM state dir
#                       (~/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware)
#   UBUNTU_PASSWORD     admin password in the guest (read from the image's
#                       vars file; override after changing it in the guest)
#   NO_COLOR            disable colored output (any non-empty value)
#
# Requires macOS on Apple Silicon, VMware Fusion (vmrun), and expect
# (ships with macOS) for the SSH password prompt.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- config ------------------------------------------------------------------

image_name=sandbox-ubuntu-24-04-arm64-vmware
platform_dir="$repo_root/images/ubuntu-arm64-vmware"
vars_file="$platform_dir/vars/${image_name}.pkrvars.hcl"
host_state_dir="${SANDBOX_STATE_DIR:-$HOME/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware}"
work_vmx="$host_state_dir/working/${image_name}.vmx"

# --- shared library ----------------------------------------------------------

# scripts/lib/vmware.sh: vmrun resolution (PATH > Fusion app bundle).
# shellcheck source=scripts/lib/vmware.sh
source "$repo_root/scripts/lib/vmware.sh"

# scripts/lib/ubuntu-vmware/settings.sh: the user-settings copy logic
# (shared with run-ubuntu-vmware-sandbox.sh).
# shellcheck source=scripts/lib/ubuntu-vmware/settings.sh
source "$repo_root/scripts/lib/ubuntu-vmware/settings.sh"

# --- output helpers (same conventions as the other runners) ------------------

c_bold=''; c_green=''; c_reset=''
ce_bold=''; ce_red=''; ce_yellow=''; ce_reset=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$(printf '\033[1m')
    c_green=$(printf '\033[32m')
    c_reset=$(printf '\033[0m')
fi
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    ce_bold=$(printf '\033[1m'); ce_red=$(printf '\033[31m')
    ce_yellow=$(printf '\033[33m'); ce_reset=$(printf '\033[0m')
fi

die() { printf '%s\n' "${ce_bold}${ce_red}$(basename "$0"): $*${ce_reset}" >&2; exit 1; }
warn() { printf '%s\n' "${ce_bold}${ce_yellow}$(basename "$0"): warning: $*${ce_reset}" >&2; }
title() { printf '%s\n' "${c_bold}$*${c_reset}"; }
info()  { printf '%s\n' "    $*"; }
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

# --- vars file helpers -------------------------------------------------------

# Same sed pattern as scripts/build.sh: pulls a quoted string variable out
# of the vars file.
read_var() {
    sed -n \
        "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\"[[:space:]]*$/\1/p" \
        "$vars_file" 2>/dev/null | head -n1
}

yes=0

usage() {
    cat <<'EOF'
Usage: sync-ubuntu-vmware-sandbox.sh [options]

Copies the host's user settings into the Ubuntu sandbox guest on demand: the
global opencode config (json, tui, agents, commands, modes, plugins, skills,
tools, themes) + auth, the OpenCodeReview config (~/.opencodereview/), the
Copilot CLI config + skills (~/.copilot/config.json, ~/.copilot/skills/), the
VS Code extensions (~/.vscode/extensions) and user config (settings.json,
keybindings.json, snippets/), the mcp-compress-router settings, ~/.ssh
(allowed_signers, known_hosts, *.sh) and ~/.gitconfig (see
docs/ubuntu-vmware.md). The VM must be running.
Updates the guest's settings marker, so run-ubuntu-vmware-sandbox.sh won't
re-offer the copy, and restarts OpenChamber so the new settings take effect.

Options:
  --yes, -y  Copy without asking for confirmation
  -h, --help Show this help

Environment:
  SANDBOX_STATE_DIR  working VM state dir
                     (~/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware)
  UBUNTU_PASSWORD    admin password in the guest
  NO_COLOR           disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes | -y) yes=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

# --- prerequisites -----------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "this script runs on macOS only."
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon required (the sandbox is ARM64-only)."
[ -n "$vmrun_bin" ] ||
    die "vmrun not found — install VMware Fusion (free for personal use) or set FUSION_APP_PATH."

[ -f "$vars_file" ] || die "vars file not found: $vars_file"
guest_user=$(read_var ssh_username)
[ -n "$guest_user" ] || guest_user=admin
guest_password=${UBUNTU_PASSWORD:-$(read_var ssh_password)}
[ -n "$guest_password" ] || die "could not read ssh_password from $vars_file"

[ -f "$work_vmx" ] ||
    die "no working VM at $work_vmx — run ./scripts/run-ubuntu-vmware-sandbox.sh first."
if ! vmrun list 2>/dev/null | grep -q "$work_vmx"; then
    die "the sandbox VM is not running — start it with ./scripts/run-ubuntu-vmware-sandbox.sh first."
fi

title "Syncing user settings into the Ubuntu sandbox"

# --- guest IP ----------------------------------------------------------------

# vmrun's getGuestIPAddress has no timeout, so poll with the perl alarm
# wrapper (same as the runner). Strict: a dotted-quad only — the error text
# ("The VMware Tools are not running…") must never become the guest IP.
guest_ip=
n=0
printf '%s' "    Waiting for the guest IP (open-vm-tools; up to 15 min)"
while [ "$n" -lt 180 ]; do
    ip=$(perl -e 'alarm 30; exec @ARGV' vmrun -T fusion getGuestIPAddress "$work_vmx" 2>/dev/null | tail -n1) || true
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [ "$ip" != "0.0.0.0" ]; then
        printf ' %s\n' "${c_green}done${c_reset}"
        guest_ip=$ip
        break
    fi
    n=$((n + 1))
    printf '.'
    sleep 5
done
[ -n "$guest_ip" ] ||
    die "timed out waiting for the guest IP — are open-vm-tools running in the guest?"

ok "Guest IP: $guest_ip"

# --- copy --------------------------------------------------------------------

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
    ok "Done — settings synced into the sandbox guest."
else
    warn "Settings are in the guest, but OpenChamber could not be restarted —"
    warn "run 'systemctl --user restart agent-sandbox-openchamber' inside the guest, or re-run this script."
fi
