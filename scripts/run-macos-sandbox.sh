#!/bin/sh
#
# run-macos-sandbox.sh — pull (if needed), run, and wire up a macOS sandbox VM.
#
# Usage:
#   ./scripts/run-macos-sandbox.sh [--headless] [--foreground] [--no-agent]
#                                  [--no-settings]
#
# What it does:
#   1. Makes sure the sandbox image is pulled and a working VM exists
#      (asks before pulling / cloning, see docs/macos.md).
#   2. Runs the VM with the recommended settings from docs/macos.md
#      (--no-audio, shared work directory; 8 CPUs / 16 GB / display-refit
#      applied when the VM is first cloned). By default the VM runs in the
#      background: 'tart run' is nohup'd to a log file, the script exits
#      after the summary, and the VM keeps running (stop it later with
#      'tart stop'). Pass --foreground to keep the terminal attached and
#      block until the VM stops instead. When the VM is already running,
#      the script asks whether to restart it.
#   3. If the host's SSH_AUTH_SOCK is overridden by a password manager
#      (Bitwarden, 1Password, ...), bridges the agent into the guest with
#      socat (see docs/ssh-agent.md). The bridge is persisted inside the
#      guest (~/.zprofile + socat auto-restart, survives guest reboots); the
#      host-side socat is only started for this run and is never persisted
#      in the host's shell profile.
#   4. Offers to copy the host's user settings into the guest — opencode
#      config + auth, ~/.ssh/allowed_signers, ~/.ssh/known_hosts,
#      ~/.ssh/*.sh, ~/.gitconfig (see docs/macos.md). Runs once per guest:
#      a versioned marker inside the guest tracks what was copied, and
#      bumping the settings version below re-copies when settings change.
#      OpenChamber is restarted after a copy so it picks up the new
#      settings.
#   5. Verifies that OpenChamber is up and offers to open it in the browser.
#
# Output: colored, step-by-step status with a summary block at the end.
# Colors are used only when the output is a terminal — piped/redirected
# output stays plain. Set NO_COLOR to force plain text.
#
# Environment (defaults in parentheses):
#   SANDBOX_IMAGE              pristine image VM to pull/clone from
#                              (sandbox-macos-tahoe)
#   SANDBOX_VM                 working VM name (sandbox-macos)
#   SANDBOX_WORK_DIR           host dir to share into the guest; empty disables
#                              the mount ( /Volumes/dev )
#   SANDBOX_MOUNT_NAME         mount name inside the guest (dev)
#   SANDBOX_AGENT_PORT         TCP port for the SSH agent bridge (4100)
#   SANDBOX_OPENCHAMBER_PORT   guest port of OpenChamber (3000)
#   SANDBOX_CPU_COUNT          CPUs for a freshly cloned VM (8)
#   SANDBOX_MEMORY_MB          RAM for a freshly cloned VM, in MB (16384)
#   GHCR_OWNER                 GHCR owner for pulls (default: from git remote)
#   NO_COLOR                   disable colored output (any non-empty value)
#
# Requires tart (brew install cirruslabs/cli/tart); socat on the host
# (brew install socat) only when an SSH agent bridge is needed.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- configuration ----------------------------------------------------------

image=${SANDBOX_IMAGE:-sandbox-macos-tahoe}
vm=${SANDBOX_VM:-sandbox-macos}
work_dir=${SANDBOX_WORK_DIR:-/Volumes/dev}
mount_name=${SANDBOX_MOUNT_NAME:-dev}
agent_port=${SANDBOX_AGENT_PORT:-4100}
openchamber_port=${SANDBOX_OPENCHAMBER_PORT:-3000}
cpu_count=${SANDBOX_CPU_COUNT:-8}
memory_mb=${SANDBOX_MEMORY_MB:-16384}

headless=0
skip_agent=0
skip_settings=0
# Run 'tart run' in the background by default (the script exits, the VM keeps
# running). --foreground sets this to 0: the script blocks until the VM stops
# and Cmd+C in the terminal stops it too.
detached=1

tart_pid=
tart_log=
bridge_pid=
vm_ip=
agent_bridged=0
guest_bridge_up=0
openchamber_up=0
settings_state=

# Version of the user settings copied into the guest (step 4). Bump this when
# new files are added to collect_settings_files: guests whose marker is older
# than this are offered the copy again.
settings_version=1

# --- output helpers ----------------------------------------------------------
#
# Colors are used only when the respective stream is a terminal and NO_COLOR
# is unset, so piped/redirected output and logs stay plain. Everything falls
# back to plain text in that case.

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
    printf '%s\n' "${ce_bold}${ce_red}run-macos-sandbox.sh: $*${ce_reset}" >&2
    exit 1
}

warn() {
    printf '%s\n' "${ce_bold}${ce_yellow}run-macos-sandbox.sh: warning: $*${ce_reset}" >&2
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

# Prints the path of the host's SSH agent socket when it is overridden, or
# nothing when the stock macOS agent (or no agent at all) is in use.
#
# "Overridden" means SSH_AUTH_SOCK points somewhere other than the default
# macOS launchd agent socket — e.g. a password manager's agent (Bitwarden,
# 1Password, ...). The default launchd agent is not bridged.
find_host_agent_socket() {
    case "${SSH_AUTH_SOCK:-}" in
        '' | /var/run/com.apple.launchd.*/Listeners)
            return 1
            ;;
        *)
            if [ -S "$SSH_AUTH_SOCK" ]; then
                printf '%s\n' "$SSH_AUTH_SOCK"
                return 0
            fi
            warn "SSH_AUTH_SOCK points to '$SSH_AUTH_SOCK', but no such socket exists."
            return 1
            ;;
    esac
}

# Prints the VM's IP, fetching (and caching) it on first use. Retries the
# fetch when the VM was not reachable yet (empty cache).
get_vm_ip() {
    if [ -z "$vm_ip" ]; then
        vm_ip=$(tart ip "$vm" 2>/dev/null || true)
    fi
    printf '%s' "$vm_ip"
}

# --- step 1: pull / clone ---------------------------------------------------

pull_image() {
    owner=${GHCR_OWNER:-}
    if [ -z "$owner" ]; then
        owner=$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null |
            sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#/[^/]*$##')
    fi
    if [ -z "$owner" ]; then
        printf 'GHCR owner not found (set GHCR_OWNER or add a git remote). Enter it: '
        read -r owner || true
    fi
    [ -n "$owner" ] || die "no GHCR owner — cannot pull. Set GHCR_OWNER, e.g. GHCR_OWNER=my-org."

    registry="ghcr.io/$owner/agent-sandbox/macos/$image"
    info "Pulling $registry:latest (one-time, ~50 GB download)..."
    tart pull "$registry:latest" || die "pull failed — check your network connection (public GHCR images pull without a login)."
}

ensure_vm() {
    if vm_exists "$vm"; then
        ok "Working VM '$vm' found (state: $(vm_state "$vm"))."
        return 0
    fi

    if vm_exists "$image"; then
        info "Sandbox image '$image' is present."
    else
        info "Sandbox image '$image' is not pulled on this machine."
        if confirm "Pull it now?" y; then
            pull_image
        else
            die "aborted — no sandbox image available. Run 'tart pull' manually when ready."
        fi
    fi

    img_state=$(vm_state "$image")
    if [ "$img_state" = running ]; then
        die "image VM '$image' is running — stop it first: tart stop $image"
    fi

    if confirm "No working VM '$vm' yet — clone it from the pristine image '$image'?" y; then
        cmd "tart clone $image $vm"
        tart clone "$image" "$vm"
        created=1
        ok "Cloned '$vm' from '$image'."
    else
        die "aborted — '$vm' is required. Clone it manually with 'tart clone $image $vm'."
    fi
}

# --- step 2: run with recommended settings ----------------------------------

apply_recommended_settings() {
    cmd "tart set $vm --cpu $cpu_count --memory $memory_mb --display 1280x800 --display-refit"
    tart set "$vm" --cpu "$cpu_count" --memory "$memory_mb" --display 1280x800 --display-refit
    ok "Applied recommended settings: $cpu_count CPUs / $((memory_mb / 1024)) GB / 1280x800 display-refit."
}

launch_vm() {
    dir_arg=
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        dir_arg="--dir=$mount_name:$work_dir"
    elif [ -n "$work_dir" ]; then
        warn "work directory '$work_dir' does not exist — skipping the shared-directory mount."
    fi

    if [ "$headless" = 1 ]; then
        flags='--no-graphics --no-audio'
    else
        flags='--no-audio'
    fi
    if [ -n "$dir_arg" ]; then
        run_cmd="tart run $flags $dir_arg $vm"
    else
        run_cmd="tart run $flags $vm"
    fi
    cmd "$run_cmd"

    # shellcheck disable=SC2086
    if [ "$detached" = 1 ]; then
        # Background: nohup the VM so it survives this script exiting, and
        # keep its output in a log file. The VM lives inside the 'tart run'
        # process itself, so it keeps running exactly as long as that process
        # does — nohup keeps it alive after the script is gone.
        tart_log="$HOME/Library/Logs/agent-sandbox/tart-$vm.log"
        mkdir -p "${tart_log%/*}"
        info "Running the VM in the background (output: $tart_log)."
        if [ -n "$dir_arg" ]; then
            nohup tart run $flags "$dir_arg" "$vm" >>"$tart_log" 2>&1 &
        else
            nohup tart run $flags "$vm" >>"$tart_log" 2>&1 &
        fi
    else
        if [ -n "$dir_arg" ]; then
            tart run $flags "$dir_arg" "$vm" &
        else
            tart run $flags "$vm" &
        fi
    fi
    tart_pid=$!

    # Wait for the VM to actually boot (up to 3 minutes).
    n=0
    printf '%s' "    Waiting for the VM to boot (up to 3 min)"
    while [ "$n" -lt 90 ]; do
        if ! kill -0 "$tart_pid" 2>/dev/null; then
            die "'tart run' exited before the VM started."
        fi
        if [ "$(vm_state "$vm")" = running ]; then
            printf ' %s\n' "${c_green}done${c_reset}"
            ip=$(get_vm_ip)
            if [ -n "$ip" ]; then
                ok "VM is running (IP: $ip)."
            else
                ok "VM is running."
            fi
            return 0
        fi
        n=$((n + 1))
        printf '.'
        sleep 2
    done
    die "timed out waiting for '$vm' to boot."
}

# --- step 3: SSH agent bridge (docs/ssh-agent.md) ----------------------------

start_host_bridge() {
    sock="$1"

    if ! command -v socat >/dev/null 2>&1; then
        warn "socat is not installed on the host."
        if confirm "Install it with 'brew install socat' now?" y; then
            brew install socat || return 1
        else
            return 1
        fi
    fi

    if lsof -nP -iTCP:"$agent_port" -sTCP:LISTEN >/dev/null 2>&1; then
        ok "A listener is already bound to TCP port $agent_port — assuming the bridge is up."
        return 0
    fi

    # The host's address on Tart's VM network: every VM is on the same /24 and
    # the host is always .1 (see docs/ssh-agent.md).
    gw=$(tart ip "$vm" | awk -F. '{print $1"."$2"."$3".1"}')
    if [ -z "$gw" ]; then
        warn "could not determine the host gateway address ('tart ip $vm' failed)."
        return 1
    fi

    cmd "socat TCP-LISTEN:$agent_port,reuseaddr,fork,bind=$gw -> $sock"
    socat TCP-LISTEN:"$agent_port",reuseaddr,fork,bind="$gw" UNIX-CONNECT:"$sock" &
    bridge_pid=$!
    sleep 1
    if kill -0 "$bridge_pid" 2>/dev/null; then
        ok "Host bridge is up (pid $bridge_pid)."
        return 0
    fi
    warn "host bridge exited immediately — check the agent socket path."
    bridge_pid=
    return 1
}

# Persist the SSH agent setup in the guest's ~/.zprofile: the SSH_AUTH_SOCK
# export plus a bridge auto-restart, so every new guest shell gets the agent.
# Idempotent — does nothing when the marker is already present.
persist_guest_agent() {
    if ! tart exec -i "$vm" sh -s "$agent_port" 2>/dev/null <<'GUEST_ZPROFILE'
port=$1
if ! grep -qF '# SSH agent bridge to the host' "$HOME/.zprofile" 2>/dev/null; then
    {
        printf '\n%s\n' '# SSH agent bridge to the host (see docs/ssh-agent.md)'
        printf '%s\n' \
            'if [ -z "${SSH_AUTH_SOCK:-}" ] || [ "$SSH_AUTH_SOCK" != "/tmp/ssh-agent.sock" ]; then' \
            '    export SSH_AUTH_SOCK=/tmp/ssh-agent.sock' \
            'fi' \
            'if ! pgrep -f "UNIX-LISTEN:/tmp/ssh-agent.sock" >/dev/null 2>&1 && command -v socat >/dev/null 2>&1; then' \
            "    HOST_GW=\$(netstat -nr | awk '/default/{print \$2; exit}')" \
            "    nohup socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,unlink-early,mode=600 TCP:\"\$HOST_GW\":$port >/dev/null 2>&1 &" \
            'fi'
    } >> "$HOME/.zprofile"
fi
GUEST_ZPROFILE
    then
        warn "could not update the guest's ~/.zprofile."
    fi
}

# Returns 0 when the guest bridge is already persisted in the guest's
# ~/.zprofile.
guest_bridge_installed() {
    tart exec "$vm" sh -c 'grep -qF "# SSH agent bridge to the host" "$HOME/.zprofile" 2>/dev/null' 2>/dev/null
}

# Point the guest's ssh(1) at the bridged agent socket via ~/.ssh/config
# (IdentityAgent), so authentication works even where SSH_AUTH_SOCK is not
# exported (tart exec, cron, launchd jobs, GUI tools, ...). Separate from the
# ~/.zprofile export, so guests set up before this patch get it too.
# Idempotent — does nothing when the marker is already present.
ensure_guest_ssh_config() {
    if ! tart exec -i "$vm" sh -s 2>/dev/null <<'GUEST_SSHCONFIG'
if ! grep -qF '# SSH agent bridge to the host' "$HOME/.ssh/config" 2>/dev/null; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    {
        printf '\n%s\n' '# SSH agent bridge to the host (see docs/ssh-agent.md)'
        printf '%s\n' \
            'Host *' \
            '    IdentityAgent /tmp/ssh-agent.sock'
    } >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
fi
GUEST_SSHCONFIG
    then
        warn "could not update the guest's ~/.ssh/config."
    fi
}

# Start the guest bridge for this boot (survives the tart exec session) and
# report whether it is up.
ensure_guest_bridge() {
    guest_sock=/tmp/ssh-agent.sock
    guest_status=
    if ! guest_status=$(tart exec -i "$vm" sh -s "$agent_port" 2>/dev/null <<'GUEST_BRIDGE'
port=$1
if ! pgrep -f 'UNIX-LISTEN:/tmp/ssh-agent.sock' >/dev/null 2>&1; then
    HOST_GW=$(netstat -nr | awk '/default/{print $2; exit}')
    nohup socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,unlink-early,mode=600 \
        TCP:"$HOST_GW":$port >/dev/null 2>&1 &
fi
sleep 1
if pgrep -f 'UNIX-LISTEN:/tmp/ssh-agent.sock' >/dev/null 2>&1; then
    echo guest-bridge-up
else
    echo guest-bridge-failed
fi
GUEST_BRIDGE
); then
        guest_status=guest-bridge-failed
    fi

    case "$guest_status" in
        guest-bridge-up)
            guest_bridge_up=1
            ok "Guest bridge is up: $guest_sock -> host TCP $agent_port"
            ;;
        *)
            warn "guest bridge did not start — run the guest commands from docs/ssh-agent.md manually."
            ;;
    esac
}

# --- step 3 (cont.): SSH agent setup ----------------------------------------

setup_ssh_agent() {
    sock=
    if ! sock=$(find_host_agent_socket); then
        sock=
    fi
    if [ -z "$sock" ]; then
        info "No SSH agent override detected — using the default macOS agent."
        info "To share a password manager's agent (Bitwarden, 1Password, ...),"
        info "enable its SSH agent on the host and re-run."
        return 0
    fi

    ok "Host SSH agent socket found: $sock"
    info "Bridging it into '$vm' on TCP port $agent_port (see docs/ssh-agent.md)."

    if ! start_host_bridge "$sock"; then
        warn "skipping the SSH agent bridge."
        return 0
    fi
    agent_bridged=1

    # The guest side is persisted inside the guest (~/.zprofile) — only offer
    # to set it up when it isn't already there. Either way, make sure the
    # bridge is running for this boot.
    if guest_bridge_installed; then
        info "Guest bridge is already set up in the guest's ~/.zprofile."
        ensure_guest_bridge
        ensure_guest_ssh_config
    elif confirm "Set up the bridge inside the guest too (guest socat + ~/.zprofile + ~/.ssh/config)?" y; then
        persist_guest_agent
        ensure_guest_bridge
        ensure_guest_ssh_config
    else
        info "Guest bridge not configured — to do it manually, run the guest commands from docs/ssh-agent.md."
    fi
}

# --- step 4: user settings ----------------------------------------------------
#
# Copies the host's user settings into the guest: opencode config + auth,
# ~/.ssh/allowed_signers, ~/.ssh/known_hosts, ~/.ssh/*.sh and ~/.gitconfig.
# Runs once per guest — a versioned marker file inside the guest
# (~/.config/agent-sandbox/settings-copied) records which settings version
# was copied; guests with an older marker are offered the copy again, so
# bumping $settings_version re-runs the step when new settings are added.

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

# Prints the host's user settings files, one per line, as paths relative to
# $HOME (tarable with -C "$HOME" and displayed with $HOME/). Only files that
# actually exist are listed.
collect_settings_files() {
    for f in \
        ".config/opencode/opencode.json" \
        ".config/opencode/opencode.jsonc" \
        ".local/share/opencode/auth.json" \
        ".ssh/allowed_signers" \
        ".ssh/known_hosts" \
        ".gitconfig"; do
        [ -f "$HOME/$f" ] && printf '%s\n' "$f"
    done
    # Shell scripts in ~/.ssh (helpers for signing, host config, ...).
    for f in "$HOME"/.ssh/*.sh; do
        [ -f "$f" ] && printf '%s\n' "${f#"$HOME"/}"
    done
    return 0
}

setup_user_settings() {
    if guest_settings_installed; then
        ok "User settings are already in the guest (version $settings_version) — skipping."
        settings_state=uptodate
        return 0
    fi

    settings_list=$(collect_settings_files)
    if [ -z "$settings_list" ]; then
        info "No user settings found on the host (opencode config/auth, ~/.ssh, ~/.gitconfig) — nothing to copy."
        settings_state=none
        return 0
    fi

    info "Found on the host — will copy into the guest's home directory:"
    printf '%s\n' "$settings_list" | while IFS= read -r f; do
        info "  $HOME/$f"
    done
    if ! confirm "Copy these user settings into the guest?" y; then
        info "Skipped — re-run the script to copy them later."
        settings_state=declined
        return 0
    fi

    # Ship the files as a tar stream over `tart exec` stdin (no password
    # needed, file modes preserved). The .ssh dir may not exist in the guest
    # yet — tar creates it, then tighten it to 700 like ssh expects.
    if ! printf '%s\n' "$settings_list" | tar -C "$HOME" -cf - -T - |
        tart exec -i "$vm" sh -c 'tar -C "$HOME" -xf - || exit 1; chmod 700 "$HOME/.ssh" 2>/dev/null || true'; then
        warn "could not copy the user settings into the guest."
        settings_state=failed
        return 1
    fi

    # Record the version that was copied, so the step runs only once (until
    # $settings_version is bumped).
    if ! tart exec -i "$vm" sh -s "$settings_version" <<'GUEST_SETTINGS_MARKER'
version=$1
mkdir -p "$HOME/.config/agent-sandbox"
printf '%s\n' "$version" > "$HOME/.config/agent-sandbox/settings-copied"
GUEST_SETTINGS_MARKER
    then
        warn "settings were copied, but the version marker could not be written — they will be offered again next run."
        settings_state=failed
        return 1
    fi

    count=$(printf '%s\n' "$settings_list" | wc -l | tr -d ' ')
    settings_state=copied
    ok "Copied $count file(s) into the guest."
}

# OpenChamber runs the opencode CLI under the hood (LaunchAgent
# dev.openchamber.web), so it holds the settings it started with. Restart it
# after a copy so a fresh opencode config and auth take effect without a
# guest reboot or manual 'openchamber restart'. Non-fatal: if it isn't up yet
# (still starting at login), verify_openchamber below still waits for it.
restart_openchamber() {
    # The openchamber CLI is npm-global via nvm, so it is only on PATH in
    # login shells — source ~/.zprofile first, like the image provisioners do.
    if ! tart exec -i "$vm" sh -s 2>/dev/null <<'GUEST_OC_RESTART'
. "$HOME/.zprofile" 2>/dev/null || true
exec openchamber restart
GUEST_OC_RESTART
    then
        warn "could not restart OpenChamber — it will pick up the new settings on its next start."
        return 1
    fi
    ok "Restarted OpenChamber so it picks up the new user settings."
}

# --- step 5: OpenChamber -----------------------------------------------------

verify_openchamber() {
    n=0
    printf '%s' "    Waiting for OpenChamber (up to 120 s)"
    while [ "$n" -lt 60 ]; do
        # Recompute the URL every iteration: the VM's IP may only become
        # available after the "running" state (get_vm_ip retries the fetch).
        url="http://$(get_vm_ip):$openchamber_port"
        if curl -fsS -o /dev/null --max-time 3 "$url" 2>/dev/null; then
            printf ' %s\n' "${c_green}done${c_reset}"
            openchamber_up=1
            ok "OpenChamber is up: $url (default password: sandbox)"
            if confirm "Open it in your browser now?" y; then
                open "$url" 2>/dev/null || warn "could not open a browser — open $url manually."
            fi
            return 0
        fi
        n=$((n + 1))
        printf '.'
        sleep 2
    done
    printf '\n'
    warn "OpenChamber did not respond on $url within 120s."
    warn "check it from inside the VM: openchamber status / openchamber logs"
    return 1
}

# --- summary ----------------------------------------------------------------

print_summary() {
    ip=$(get_vm_ip)
    state=$(vm_state "$vm")
    [ -n "$state" ] || state='stopped'
    if [ -n "$ip" ]; then
        ip_str="$ip"
        ip_desc="IP $ip"
    else
        ip_str=''
        ip_desc='IP unavailable'
    fi

    step "Sandbox is ready"
    printf '    %-12s %s\n' 'VM:' "${c_bold}$vm${c_reset} ($state, $ip_desc)"
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        # Tart mounts --dir shares under "/Volumes/My Shared Files/<name>"
        # inside the guest (see docs/macos.md).
        printf '    %-12s %s\n' 'Shared dir:' "$work_dir (in the guest: /Volumes/My Shared Files/$mount_name)"
    else
        printf '    %-12s %s\n' 'Shared dir:' 'not shared'
    fi
    if [ "$agent_bridged" = 1 ]; then
        if [ "$guest_bridge_up" = 1 ]; then
            printf '    %-12s %s\n' 'SSH agent:' "${c_green}host agent -> TCP $agent_port -> guest ($guest_sock)${c_reset}"
        else
            printf '    %-12s %s\n' 'SSH agent:' "${c_yellow}host bridge up (TCP $agent_port), guest bridge not running${c_reset}"
        fi
    else
        printf '    %-12s %s\n' 'SSH agent:' 'not bridged'
    fi
    case "$settings_state" in
        copied)
            printf '    %-12s %s\n' 'Settings:' "${c_green}copied into the guest (version $settings_version)${c_reset}"
            ;;
        uptodate)
            printf '    %-12s %s\n' 'Settings:' "already in the guest (version $settings_version)"
            ;;
        skipped)
            printf '    %-12s %s\n' 'Settings:' 'not copied (--no-settings)'
            ;;
        none)
            printf '    %-12s %s\n' 'Settings:' 'nothing to copy on the host'
            ;;
        failed)
            printf '    %-12s %s\n' 'Settings:' "${c_yellow}copy failed — re-run the script to retry${c_reset}"
            ;;
        *)
            printf '    %-12s %s\n' 'Settings:' 'not copied'
            ;;
    esac
    if [ "$openchamber_up" = 1 ]; then
        printf '    %-12s %s\n' 'OpenChamber:' "${c_green}http://$ip_str:$openchamber_port (password: sandbox)${c_reset}"
    elif [ -n "$ip_str" ]; then
        printf '    %-12s %s\n' 'OpenChamber:' "${c_yellow}not responding on http://$ip_str:$openchamber_port${c_reset}"
    else
        printf '    %-12s %s\n' 'OpenChamber:' "${c_yellow}not responding (VM IP unavailable)${c_reset}"
    fi
    # Foreground mode only: while the VM runs, this script occupies the
    # terminal (it blocks in 'wait'), so 'tart stop' must be typed in a
    # separate terminal. Cmd+C works right here: the backgrounded 'tart run'
    # shares the script's process group, so the terminal's SIGINT reaches
    # and stops the VM too. In background mode the script has already
    # returned, so the terminal is free — plain 'tart stop' suffices.
    if [ "$detached" = 1 ]; then
        stop_hint="run 'tart stop $vm'"
    elif [ "$headless" = 1 ]; then
        stop_hint="run 'tart stop $vm' in another terminal"
    elif [ -n "$tart_pid" ]; then
        stop_hint="press Cmd+C in this terminal, or run 'tart stop $vm' in another terminal"
    else
        stop_hint="run 'tart stop $vm'"
    fi
    printf '    %-12s %s\n' 'Stop:' "$stop_hint"
    if [ "$detached" = 1 ] && [ -n "$tart_pid" ]; then
        printf '    %-12s %s\n' 'Background:' "VM keeps running after this script exits (tart log: $tart_log)"
        if [ "$agent_bridged" = 1 ]; then
            printf '    %-12s %s\n' 'Bridge:' "host socat listener on TCP $agent_port stays up — kill with: lsof -tiTCP:$agent_port -sTCP:LISTEN | xargs kill"
        fi
    fi
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: run-macos-sandbox.sh [options]

Pulls (if needed), runs, and wires up a macOS sandbox VM.

By default the VM runs in the background: the script exits after the summary
and the VM keeps running (stop it later with 'tart stop <vm>'; tart output
goes to ~/Library/Logs/agent-sandbox/tart-<vm>.log).

Options:
  --headless     Run without a window (tart run --no-graphics)
  --foreground   Keep the terminal attached and block until the VM stops
                 (Cmd+C in the terminal stops the VM)
  --no-agent     Skip the SSH agent bridge setup
  --no-settings  Skip copying the host's user settings into the guest
  -h, --help     Show this help

Environment:
  SANDBOX_IMAGE              image VM to pull/clone from (sandbox-macos-tahoe)
  SANDBOX_VM                 working VM name (sandbox-macos)
  SANDBOX_WORK_DIR           host dir to share ( /Volumes/dev ; empty = no share)
  SANDBOX_MOUNT_NAME         mount name inside the guest (dev)
  SANDBOX_AGENT_PORT         TCP port for the SSH agent bridge (4100)
  SANDBOX_OPENCHAMBER_PORT   guest port of OpenChamber (3000)
  SANDBOX_CPU_COUNT          CPUs for a freshly cloned VM (8)
  SANDBOX_MEMORY_MB          RAM for a freshly cloned VM, in MB (16384)
  GHCR_OWNER                 GHCR owner for pulls (git remote)
  NO_COLOR                   disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        --headless) headless=1 ;;
        --foreground) detached=0 ;;
        --no-agent) skip_agent=1 ;;
        --no-settings) skip_settings=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

command -v tart >/dev/null 2>&1 ||
    die "tart is not installed — run 'brew install cirruslabs/cli/tart' first."

# Stop the host socat bridge on exit, but only in foreground mode and only
# when this script launched the VM itself. In background mode the VM (and its
# need for the bridge) outlives this script, so the bridge must stay up — and
# when the VM was already running the script exits right after the bridge
# setup for the same reason. The host bridge is never persisted; the guest
# side is (see persist_guest_agent). Re-running the script is idempotent —
# see the port check in start_host_bridge.
cleanup() {
    if [ "$detached" = 0 ] && [ -n "$bridge_pid" ] && [ -n "$tart_pid" ]; then
        kill "$bridge_pid" 2>/dev/null || true
        info "Stopped the host socat bridge (pid $bridge_pid)."
    fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

if [ "$headless" = 1 ]; then
    mode='headless'
else
    mode='gui'
fi
title "macOS sandbox: $vm (image: $image, $mode mode)"

# 1. Make sure the sandbox is pulled and a working VM exists.
created=0
step "Step 1/5: Sandbox image and working VM"
ensure_vm

# 2. Run it with the recommended settings.
step "Step 2/5: Starting the VM"
if [ "$(vm_state "$vm")" = running ]; then
    if confirm "VM '$vm' is already running — restart it?" n; then
        cmd "tart stop $vm"
        tart stop "$vm" || die "'tart stop $vm' failed."
        n=0
        printf '%s' "    Waiting for '$vm' to stop"
        while [ "$(vm_state "$vm")" = running ] && [ "$n" -lt 60 ]; do
            printf '.'
            sleep 2
            n=$((n + 1))
        done
        if [ "$(vm_state "$vm")" = running ]; then
            die "timed out waiting for '$vm' to stop."
        fi
        printf ' %s\n' "${c_green}stopped${c_reset}"
        sleep 1  # let tart release the VM lock before running it again
        launch_vm
    else
        ok "Keeping the running VM — skipping 'tart run'."
    fi
else
    [ "$created" = 1 ] && apply_recommended_settings
    launch_vm
fi

# 3. SSH agent bridge (host bridge per run; the guest side is persisted
#    inside the guest's ~/.zprofile).
step "Step 3/5: SSH agent bridge"
if [ "$skip_agent" = 1 ]; then
    info "Skipping SSH agent bridge setup (--no-agent)."
else
    setup_ssh_agent
fi

# 4. User settings (opencode config + auth, SSH/Git dotfiles) — copied once
#    per guest, tracked by a versioned marker inside the guest.
step "Step 4/5: User settings"
if [ "$skip_settings" = 1 ]; then
    info "Skipping user settings copy (--no-settings)."
    settings_state=skipped
else
    setup_user_settings
    # OpenChamber wraps the opencode CLI — restart it so a fresh copy of the
    # settings takes effect without rebooting the guest.
    if [ "$settings_state" = copied ]; then
        restart_openchamber
    fi
fi

# 5. Verify OpenChamber and offer to open it.
step "Step 5/5: OpenChamber"
verify_openchamber || true

print_summary

if [ -n "$tart_pid" ] && [ "$detached" = 0 ]; then
    if wait "$tart_pid"; then
        info "VM '$vm' has stopped."
    else
        warn "VM '$vm' exited with an error (see tart output above)."
    fi
fi
