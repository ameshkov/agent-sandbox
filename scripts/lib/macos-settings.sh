#!/bin/sh
#
# lib/macos-settings.sh — shared helpers + user-settings copy logic for the
# macOS sandbox scripts (run-macos-sandbox.sh, sync-macos-sandbox.sh).
#
# Sourced, not executed. Provides:
#
#   Output helpers:      c_* / ce_* color vars, die, warn, title, step, info,
#                        cmd, ok, confirm
#   VM helpers:          vm_exists, vm_state
#   Settings logic:      settings_version, collect_settings_files,
#                        guest_settings_installed, copy_settings_to_guest,
#                        restart_openchamber
#
# The settings functions use the caller's $vm (guest VM name) and $HOME; the
# helpers need nothing but the terminal. Everything below is only definitions
# — sourcing this file has no side effects.
#
# Colors are used only when the respective stream is a terminal and NO_COLOR
# is unset, so piped/redirected output and logs stay plain. Everything falls
# back to plain text in that case.

script_name=${0##*/}

c_bold=''
c_dim=''
c_green=''
c_yellow=''
c_blue=''
c_reset=''
ce_bold=''
ce_red=''
ce_yellow=''
ce_reset=''

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$(printf '\033[1m')
    c_dim=$(printf '\033[2m')
    c_green=$(printf '\033[32m')
    c_yellow=$(printf '\033[33m')
    c_blue=$(printf '\033[34m')
    c_reset=$(printf '\033[0m')
fi
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    ce_bold=$(printf '\033[1m')
    ce_red=$(printf '\033[31m')
    ce_yellow=$(printf '\033[33m')
    ce_reset=$(printf '\033[0m')
fi

die() {
    printf '%s\n' "${ce_bold}${ce_red}$script_name: $*${ce_reset}" >&2
    exit 1
}

warn() {
    printf '%s\n' "${ce_bold}${ce_yellow}$script_name: warning: $*${ce_reset}" >&2
}

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
    if [ ! -t 0 ]; then
        # Non-interactive: nothing will echo the newline, so end the line
        # ourselves instead of leaving the prompt dangling on it.
        printf '\n'
    fi
    answer=
    IFS= read -r answer || return 1
    case "$answer" in
        y | Y | yes | YES) return 0 ;;
        '')
            if [ "$default" = y ]; then return 0; fi
            return 1
            ;;
    esac
    return 1
}

# Returns 0 and prints the VM name if it exists in `tart list`.
vm_exists() {
    tart list | awk -v name="$1" '$2 == name { found = 1 } END { exit !found }'
}

# Prints the state (running/stopped) of the given VM, if it exists.
vm_state() {
    tart list | awk -v name="$1" '$2 == name { print $NF; exit }'
}

# --- user settings ------------------------------------------------------------
#
# Copies the host's user settings into the guest: the global opencode config
# (opencode.json/.jsonc, tui.json/.jsonc, agents/, commands/, modes/,
# plugins/, skills/, tools/, themes/ and the config dir's package.json +
# lockfiles for local plugin dependencies), opencode auth, the Copilot CLI
# config + skills (~/.copilot/config.json, ~/.copilot/skills/), the VS Code
# extensions (~/.vscode/extensions) and user config (settings.json,
# keybindings.json, snippets/ under
# ~/Library/Application Support/Code/User/), ~/.ssh/allowed_signers,
# ~/.ssh/known_hosts, ~/.ssh/*.sh and ~/.gitconfig.
# run-macos-sandbox.sh runs this once per guest — a versioned marker file
# inside the guest (~/.config/agent-sandbox/settings-copied) records which
# settings version was copied; guests with an older marker are offered the
# copy again, so bumping $settings_version re-runs the step when new
# settings are added. sync-macos-sandbox.sh runs the same copy on demand
# and updates the marker.

# Version of the user settings copied into the guest. Bump this when new
# files are added to collect_settings_files, or when the copy logic changes
# (e.g. the .gitconfig sanitization in copy_settings_to_guest below): guests
# whose marker is older than this are offered the copy again.
settings_version=6

# Prints the host's user settings files, one per line, as paths relative to
# $HOME (tarable with -C "$HOME" and displayed with $HOME/). Only entries
# that actually exist are listed; directories (opencode agents/commands/
# modes/plugins/skills/tools/themes, copilot skills, VS Code extensions and
# snippets) are copied whole.
collect_settings_files() {
    for f in \
        ".config/opencode/opencode.json" \
        ".config/opencode/opencode.jsonc" \
        ".config/opencode/tui.json" \
        ".config/opencode/tui.jsonc" \
        ".config/opencode/agents" \
        ".config/opencode/commands" \
        ".config/opencode/modes" \
        ".config/opencode/plugins" \
        ".config/opencode/skills" \
        ".config/opencode/tools" \
        ".config/opencode/themes" \
        ".config/opencode/package.json" \
        ".config/opencode/package-lock.json" \
        ".config/opencode/bun.lock" \
        ".local/share/opencode/auth.json" \
        ".copilot/config.json" \
        ".copilot/skills" \
        ".vscode/extensions" \
        "Library/Application Support/Code/User/settings.json" \
        "Library/Application Support/Code/User/keybindings.json" \
        "Library/Application Support/Code/User/snippets" \
        ".ssh/allowed_signers" \
        ".ssh/known_hosts" \
        ".gitconfig"; do
        [ -e "$HOME/$f" ] && printf '%s\n' "$f"
    done
    # Shell scripts in ~/.ssh (helpers for signing, host config, ...).
    for f in "$HOME"/.ssh/*.sh; do
        [ -f "$f" ] && printf '%s\n' "${f#"$HOME"/}"
    done
    return 0
}

# Returns 0 when the guest already has settings of the current version.
guest_settings_installed() {
    tart exec -i "$vm" sh -s "$settings_version" <<'GUEST_SETTINGS_STATUS' 2>/dev/null
    version=$1
    marker="$HOME/.config/agent-sandbox/settings-copied"
    if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" -ge "$version" ] 2>/dev/null; then
        exit 0
    fi
    exit 1
GUEST_SETTINGS_STATUS
}

# Copies the settings — one path relative to $HOME per line on stdin — into
# $vm's home directory as a tar stream over `tart exec` stdin (no password
# needed, file modes preserved), then records the version marker so
# run-macos-sandbox.sh sees the guest as up to date. Returns 0 on success.
#
# .gitconfig is the one file that can carry host-specific paths (the host
# home directory, e.g. /Users/ameshkov, baked into the config) and the
# guest's user differs (admin), so it is sanitized before the copy: host
# home paths are rewritten to ~ (git expands ~ for path-like keys like
# gpg.ssh.allowedsignersfile, and the shell does for core.sshCommand) and
# `program` values under ~ are dropped — git execs program values verbatim
# without ~ expansion, and the gpg.ssh.program signing wrapper is a
# host-only workaround; the guest signs through the bridged SSH_AUTH_SOCK
# (set in the guest's ~/.zprofile) with the default ssh-keygen instead.
copy_settings_to_guest() {
    # Sanitize .gitconfig into a staging dir (only when the host has one);
    # the sanitized copy ships in place of the original below.
    sanitized_gitconfig=
    if [ -f "$HOME/.gitconfig" ]; then
        staging=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-settings.XXXXXX") || {
            warn "could not create a staging dir for the settings copy."
            return 1
        }
        if sed -e "s|$HOME|~|g" \
               -e '/^[[:space:]]*program[[:space:]]*=[[:space:]]*~/d' \
               "$HOME/.gitconfig" > "$staging/.gitconfig"; then
            chmod "$(stat -f %Lp "$HOME/.gitconfig")" "$staging/.gitconfig"
            sanitized_gitconfig=1
        else
            warn "could not sanitize .gitconfig — shipping it as-is."
            rm -rf "$staging"
        fi
    fi

    # The .ssh dir may not exist in the guest yet — tar creates it, then
    # tighten it to 700 like ssh expects.
    guest_unpack='tar -C "$HOME" -xf - || exit 1; chmod 700 "$HOME/.ssh" 2>/dev/null || true'
    if [ -n "$sanitized_gitconfig" ]; then
        # Two separate archives (bsdtar stops at the first end-of-archive
        # marker, so concatenated streams are unreliable): everything except
        # .gitconfig first, then the sanitized copy on its own.
        if ! tar -C "$HOME" -cf - --exclude=.gitconfig -T - |
            tart exec -i "$vm" sh -c "$guest_unpack"; then
            warn "could not copy the user settings into the guest."
            rm -rf "$staging"
            return 1
        fi
        if ! tar -C "$staging" -cf - .gitconfig |
            tart exec -i "$vm" sh -c 'tar -C "$HOME" -xf -'; then
            warn "could not copy .gitconfig into the guest."
            rm -rf "$staging"
            return 1
        fi
        rm -rf "$staging"
    elif ! tar -C "$HOME" -cf - -T - |
        tart exec -i "$vm" sh -c "$guest_unpack"; then
        warn "could not copy the user settings into the guest."
        return 1
    fi

    # Record the version that was copied, so the settings step runs only once
    # per version (until $settings_version is bumped).
    if ! tart exec -i "$vm" sh -s "$settings_version" <<'GUEST_SETTINGS_MARKER'
    version=$1
    mkdir -p "$HOME/.config/agent-sandbox"
    printf '%s\n' "$version" > "$HOME/.config/agent-sandbox/settings-copied"
GUEST_SETTINGS_MARKER
    then
        warn "settings were copied, but the version marker could not be written — they will be offered again next run."
        return 1
    fi
    return 0
}

# OpenChamber runs the opencode CLI under the hood (LaunchAgent
# dev.openchamber.web), so it holds the settings it started with. Restart it
# after a copy so a fresh opencode config and auth take effect without a
# guest reboot or manual 'openchamber restart'. Non-fatal: callers may warn
# and continue.
restart_openchamber() {
    # The openchamber CLI is npm-global via nvm, so it is only on PATH in
    # login shells — source ~/.zprofile first, like the image provisioners do.
    # Guard the source: on macOS /bin/sh (bash 3.2) sourcing a missing file is
    # a fatal error, and ~/.zprofile may not exist in a freshly cloned guest.
    if ! tart exec -i "$vm" sh -s 2>/dev/null <<'GUEST_OC_RESTART'
    if [ -f "$HOME/.zprofile" ]; then
        . "$HOME/.zprofile" 2>/dev/null || true
    fi
    exec openchamber restart
GUEST_OC_RESTART
    then
        warn "could not restart OpenChamber — it will pick up the new settings on its next start."
        return 1
    fi
    ok "Restarted OpenChamber so it picks up the new user settings."
    return 0
}
