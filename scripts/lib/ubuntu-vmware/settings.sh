#!/bin/sh
#
# lib/ubuntu-vmware/settings.sh — host user-settings copy logic for the
# Ubuntu VMware sandbox (run-ubuntu-vmware-sandbox.sh and
# sync-ubuntu-vmware-sandbox.sh).
#
# Mirrors scripts/lib/macos-settings.sh (same file set, same once-per-guest
# marker semantics) with the Linux twist: the guest is reached over SSH
# (expect drives the password prompt) instead of `tart exec`, and two host
# paths map to different guest paths — the VS Code user config
# (~/Library/Application Support/Code/User/) and the mcp-compress-router
# settings (also under ~/Library/Application Support/) live under the
# Linux XDG dirs (~/.config/Code/User/, ~/.config/mcp-compress-router/).
# The guest home is /home/admin (the image's fixed sandbox user).
#
# Sourced, not executed. Everything below is definitions only — sourcing
# this file has no side effects. The caller must provide:
#
#   Output helpers:    die, warn, info, ok (and optionally confirm)
#   Guest connection:  $guest_ip, $guest_user, $guest_password
#                      (set by the caller before calling into the
#                       settings functions)
#
# This module provides:
#
#   settings_version         version of the settings copy (bump to re-copy)
#   collect_settings_files   prints the host settings files, relative to
#                            $HOME, one per line
#   guest_settings_installed returns 0 when the guest already has the
#                            current settings version
#   copy_settings_to_guest   copies the file list from stdin into the guest
#                            and records the version marker
#   restart_openchamber      restarts OpenChamber so a fresh copy is used

# Version of the user settings copied into the guest. Bump this when new
# files are added to collect_settings_files, or when the copy logic changes
# (e.g. the .gitconfig sanitization below): guests whose marker is older
# than this are offered the copy again.
settings_version=1

# The sandbox user in the guest is fixed by the base image: admin, whose
# home is /home/admin. Host home paths are rewritten to it verbatim.
guest_home=/home/admin

# --- helpers ---------------------------------------------------------------

# settings_ssh <command> — runs a command in the guest over SSH. The
# password prompt is answered by expect; stdin passes through to the remote
# command (unused by the copy — settings travel via settings_scp), stdout
# comes back to the caller. Exits with the remote command's exit code (or 1
# on timeout). Hard 5-minute cap on the whole session (perl alarm, not
# expect's own timeout): expect's `timeout` only fires on silence, and a
# lingering ssh session can trickle output forever.
settings_ssh() {
    remote_cmd=$1
    GUEST_CMD="$remote_cmd" GUEST_PW="$guest_password" \
        perl -e 'alarm 300; exec @ARGV' expect -c '
        set timeout 240
        set cmd $env(GUEST_CMD)
        spawn ssh -p 22 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=10 -o PreferredAuthentications=password \
            '$guest_user'@'$guest_ip' $cmd
        expect {
            -re {[Pp]assword[^:]*:} { send -- "$env(GUEST_PW)\r"; exp_continue }
            timeout {
                catch { exec kill [exp_pid] }
                catch wait result
                exit 1
            }
            eof { }
        }
        catch wait result
        exit [lindex $result 3]
    '
}

# settings_scp <local-path> <guest-path> — copies one file to the guest with
# scp (the settings archive is binary and can be large — VS Code extensions;
# the tar stream is never routed through the pty of the ssh session).
settings_scp() {
    local src=$1 dst=$2
    SCPSRC="$src" SCPDST="$guest_user@$guest_ip:$dst" GUEST_PW="$guest_password" \
        perl -e 'alarm 300; exec @ARGV' expect -c '
        set timeout 240
        set src $env(SCPSRC)
        set dst $env(SCPDST)
        spawn scp -P 22 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=10 -o PreferredAuthentications=password \
            $src $dst
        expect {
            -re {[Pp]assword[^:]*:} { send -- "$env(GUEST_PW)\r"; exp_continue }
            timeout {
                catch { exec kill [exp_pid] }
                catch wait result
                exit 1
            }
            eof { }
        }
        catch wait result
        exit [lindex $result 3]
    '
}

# --- user settings ----------------------------------------------------------
#
# The file set is the same as the macOS sandbox's: the global opencode
# config (opencode.json/.jsonc, tui.json/.jsonc, agents/, commands/, modes/,
# plugins/, skills/, tools/, themes/ and the config dir's package.json +
# lockfiles for local plugin dependencies), opencode auth, the OpenCodeReview
# config (~/.opencodereview/config.json), the Copilot CLI config + skills
# (~/.copilot/), the VS Code extensions (~/.vscode/extensions) and user
# config (settings.json, keybindings.json, snippets/), the mcp-compress-router
# settings, ~/.ssh/allowed_signers, ~/.ssh/known_hosts, ~/.ssh/*.sh and
# ~/.gitconfig. The host is always macOS; the guest paths are the Linux
# ones (see the mapping in copy_settings_to_guest).

# Prints the host's user settings files, one per line, as paths relative to
# $HOME. Only entries that actually exist are listed; directories (opencode
# agents/commands/modes/plugins/skills/tools/themes, copilot skills, VS Code
# extensions and snippets, mcp-compress-router) are copied whole.
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
        ".opencodereview/config.json" \
        ".copilot/config.json" \
        ".copilot/skills" \
        ".vscode/extensions" \
        "Library/Application Support/Code/User/settings.json" \
        "Library/Application Support/Code/User/keybindings.json" \
        "Library/Application Support/Code/User/snippets" \
        "Library/Application Support/mcp-compress-router" \
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
    settings_ssh '
        marker="$HOME/.config/agent-sandbox/settings-copied"
        if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" -ge '"$settings_version"' ] 2>/dev/null; then
            exit 0
        fi
        exit 1
    ' >/dev/null 2>&1
}

# Copies the settings — one path relative to $HOME per line on stdin — into
# the guest's home directory, then records the version marker so the runner
# sees the guest as up to date. Returns 0 on success.
#
# The copy is staged into a temporary tree in the GUEST's layout first:
#   - paths under the macOS "Library/Application Support/Code/User/" land in
#     the Linux "~/.config/Code/User/" (VS Code on Linux), and the
#     mcp-compress-router settings land in "~/.config/mcp-compress-router/"
#     (XDG config) — everything else keeps the same relative path,
#   - .gitconfig is the one file that can carry host-specific paths (the host
#     home directory, e.g. /Users/ameshkov, baked into the config) and the
#     guest's user differs (admin), so it is sanitized before the copy: every
#     occurrence of the host home path is rewritten to the guest's home
#     directory (/home/admin) — an absolute path works everywhere, including
#     for `program` values that git execs verbatim without ~ expansion.
# The tree is tarred (binary-safe; file modes preserved) and moved to the
# guest over scp, then unpacked with tar over SSH — the pty of the expect
# session never carries binary data.
copy_settings_to_guest() {
    staging=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-settings.XXXXXX") || {
        warn "could not create a staging dir for the settings copy."
        return 1
    }
    tree="$staging/tree"
    mkdir -p "$tree"
    copied=0

    # Map the host (macOS) paths to the guest (Linux) layout.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            "Library/Application Support/Code/User/"*)
                g=".config/Code/User/${f#Library/Application Support/Code/User/}"
                ;;
            "Library/Application Support/mcp-compress-router"*)
                g=".config/mcp-compress-router"
                ;;
            *)
                g="$f"
                ;;
        esac
        [ "$f" = ".gitconfig" ] && continue
        mkdir -p "$tree/$(dirname "$g")"
        if ! cp -Rp "$HOME/$f" "$tree/$g"; then
            warn "could not stage $f — continuing."
            continue
        fi
        copied=$((copied + 1))
    done

    # Sanitize .gitconfig into the tree (only when the host has one).
    if [ -f "$HOME/.gitconfig" ]; then
        if sed -e "s|$HOME|$guest_home|g" \
               "$HOME/.gitconfig" > "$tree/.gitconfig"; then
            chmod "$(stat -f %Lp "$HOME/.gitconfig")" "$tree/.gitconfig"
            copied=$((copied + 1))
        else
            warn "could not sanitize .gitconfig — shipping it as-is."
            cp -p "$HOME/.gitconfig" "$tree/.gitconfig"
            copied=$((copied + 1))
        fi
    fi

    if [ "$copied" -eq 0 ]; then
        info "Nothing was staged — no settings to copy."
        rm -rf "$staging"
        return 1
    fi

    archive="$staging/settings.tar.gz"
    # --no-xattrs: macOS tar stamps every file with the
    # com.apple.provenance xattr, and the guest's GNU tar would warn per
    # file ("Ignoring unknown extended header keyword"). Modes traveled
    # through cp -p and don't need xattrs.
    if ! tar --no-xattrs -czf "$archive" -C "$tree" .; then
        warn "could not pack the staged settings."
        rm -rf "$staging"
        return 1
    fi

    # Move the archive to the guest and unpack it into the home dir. The
    # .ssh dir may not exist in the guest yet — tar creates it, then tighten
    # it to 700 like ssh expects.
    if ! settings_scp "$archive" "/tmp/agent-sandbox-settings.tar.gz"; then
        warn "could not copy the settings archive into the guest."
        rm -rf "$staging"
        return 1
    fi
    if ! settings_ssh '
        tar -C "$HOME" -xzf /tmp/agent-sandbox-settings.tar.gz || exit 1
        chmod 700 "$HOME/.ssh" 2>/dev/null || true
        rm -f /tmp/agent-sandbox-settings.tar.gz
    '; then
        warn "could not unpack the settings in the guest."
        rm -rf "$staging"
        return 1
    fi
    rm -rf "$staging"

    # Record the version that was copied, so the settings step runs only once
    # per version (until $settings_version is bumped).
    if ! settings_ssh '
        mkdir -p "$HOME/.config/agent-sandbox"
        printf "%s\n" '"$settings_version"' > "$HOME/.config/agent-sandbox/settings-copied"
    '; then
        warn "settings were copied, but the version marker could not be written — they will be offered again next run."
        return 1
    fi
    return 0
}

# OpenChamber runs the opencode CLI under the hood (systemd user service
# agent-sandbox-openchamber), so it holds the settings it started with.
# Restart it after a copy so a fresh opencode config and auth take effect
# without a guest reboot. Non-fatal: callers may warn and continue.
restart_openchamber() {
    if ! settings_ssh '
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        systemctl --user restart agent-sandbox-openchamber
    '; then
        warn "could not restart OpenChamber — it will pick up the new settings on its next start."
        return 1
    fi
    ok "Restarted OpenChamber so it picks up the new user settings."
    return 0
}
