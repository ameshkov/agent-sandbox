#!/bin/sh
#
# run-macos-sandbox.sh — pull (if needed), run, and wire up a macOS sandbox VM.
#
# Usage:
#   ./scripts/run-macos-sandbox.sh [--headless] [--no-agent]
#
# What it does:
#   1. Makes sure the sandbox image is pulled and a working VM exists
#      (asks before pulling / cloning, see docs/macos.md).
#   2. Runs the VM with the recommended settings from docs/macos.md
#      (--no-audio, shared work directory; 8 CPUs / 16 GB / display-refit
#      applied when the VM is first cloned).
#   3. If the host's SSH_AUTH_SOCK is overridden by a password manager
#      (Bitwarden, 1Password, ...), bridges the agent into the guest with
#      socat (see docs/ssh-agent.md). The bridge is persisted inside the
#      guest (~/.zprofile + socat auto-restart, survives guest reboots); the
#      host-side socat is only started for this run and is never persisted
#      in the host's shell profile.
#   4. Verifies that OpenChamber is up and offers to open it in the browser.
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

tart_pid=
bridge_pid=
vm_ip=
agent_bridged=0
guest_bridge_up=0
openchamber_up=0

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
    if [ -n "$dir_arg" ]; then
        tart run $flags "$dir_arg" "$vm" &
    else
        tart run $flags "$vm" &
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

# --- step 4: OpenChamber -----------------------------------------------------

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
    if [ "$openchamber_up" = 1 ]; then
        printf '    %-12s %s\n' 'OpenChamber:' "${c_green}http://$ip_str:$openchamber_port (password: sandbox)${c_reset}"
    elif [ -n "$ip_str" ]; then
        printf '    %-12s %s\n' 'OpenChamber:' "${c_yellow}not responding on http://$ip_str:$openchamber_port${c_reset}"
    else
        printf '    %-12s %s\n' 'OpenChamber:' "${c_yellow}not responding (VM IP unavailable)${c_reset}"
    fi
    # While the VM runs, this script occupies the terminal (it blocks in
    # 'wait'), so 'tart stop' must be typed in a separate terminal. Cmd+C
    # works right here: the backgrounded 'tart run' shares the script's
    # process group, so the terminal's SIGINT reaches and stops the VM too.
    if [ "$headless" = 1 ]; then
        stop_hint="run 'tart stop $vm' in another terminal"
    elif [ -n "$tart_pid" ]; then
        stop_hint="press Cmd+C in this terminal, or run 'tart stop $vm' in another terminal"
    else
        stop_hint="run 'tart stop $vm'"
    fi
    printf '    %-12s %s\n' 'Stop:' "$stop_hint"
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: run-macos-sandbox.sh [options]

Pulls (if needed), runs, and wires up a macOS sandbox VM.

Options:
  --headless     Run without a window (tart run --no-graphics)
  --no-agent     Skip the SSH agent bridge setup
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
        --no-agent) skip_agent=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

command -v tart >/dev/null 2>&1 ||
    die "tart is not installed — run 'brew install cirruslabs/cli/tart' first."

# Stop the host socat bridge on exit, but only when this script launched the
# VM itself. When the VM was already running the script exits right after the
# bridge setup, and the bridge must stay up to serve the guest for the rest of
# the VM's lifetime (re-running the script is idempotent — see the port check
# in start_host_bridge). The host bridge is never persisted; the guest side is
# (see persist_guest_agent).
cleanup() {
    if [ -n "$bridge_pid" ] && [ -n "$tart_pid" ]; then
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
step "Step 1/4: Sandbox image and working VM"
ensure_vm

# 2. Run it with the recommended settings.
step "Step 2/4: Starting the VM"
if [ "$(vm_state "$vm")" = running ]; then
    ok "Sandbox VM '$vm' is already running — skipping 'tart run'."
else
    [ "$created" = 1 ] && apply_recommended_settings
    launch_vm
fi

# 3. SSH agent bridge (host bridge per run; the guest side is persisted
#    inside the guest's ~/.zprofile).
step "Step 3/4: SSH agent bridge"
if [ "$skip_agent" = 1 ]; then
    info "Skipping SSH agent bridge setup (--no-agent)."
else
    setup_ssh_agent
fi

# 4. Verify OpenChamber and offer to open it.
step "Step 4/4: OpenChamber"
verify_openchamber || true

print_summary

if [ -n "$tart_pid" ]; then
    if wait "$tart_pid"; then
        info "VM '$vm' has stopped."
    else
        warn "VM '$vm' exited with an error (see tart output above)."
    fi
fi
