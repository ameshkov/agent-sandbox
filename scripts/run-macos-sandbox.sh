#!/bin/sh
#
# run-macos-sandbox.sh — pull (if needed), run, and wire up a macOS sandbox VM.
#
# Usage:
#   ./scripts/run-macos-sandbox.sh [--headless] [--foreground] [--no-agent]
#                                  [--no-docker] [--no-settings]
#
# What it does:
#   1. Makes sure the sandbox image is pulled and a working VM exists
#      (asks before pulling / cloning, see docs/macos.md).
#   2. Runs the VM with the recommended settings from docs/macos.md
#      (--no-audio, shared work directory; 8 CPUs / 16 GB / display-refit
#      applied when the VM is first cloned). By default the VM runs in the
#      background: 'tart run' is nohup'd to a log file, the script exits
#      after the summary, and the VM keeps running (stop it later with
#      ./scripts/stop-macos-sandbox.sh). Pass --foreground to keep the
#      terminal attached and block until the VM stops instead. Windowed
#      runs capture system
#      shortcuts (Cmd+Space, Cmd+Tab, ...) into the guest by default, so
#      Spotlight and the app switcher work inside the VM. When the VM is
#      already running, the script asks whether to restart it.
#   3. If the host's SSH_AUTH_SOCK is overridden by a password manager
#      (Bitwarden, 1Password, ...), bridges the agent into the guest with
#      socat (see docs/ssh-agent.md). The bridge is persisted inside the
#      guest (~/.zprofile + socat auto-restart, survives guest reboots); the
#      host-side socat is only started for this run and is never persisted
#      in the host's shell profile.
#   4. If the host runs a Docker engine (Docker Desktop, Colima, OrbStack,
#      ... — anything with a Unix socket), bridges its socket into the guest
#      the same way: a host-side socat for this run, and a guest-side socat
#      plus a docker context 'host' persisted inside the guest, so `docker`
#      and `docker compose` in the guest just work against the host engine.
#      The guest's ~/.zprofile also exports DOCKER_HOST and
#      TESTCONTAINERS_HOST_OVERRIDE (the NAT gateway), so docker clients that
#      don't read contexts — e.g. container-based test frameworks like
#      testcontainers — find the engine and reach published ports too (see
#      docs/macos.md, "Docker (remote engine)"). --no-docker skips.
#      Also installs the sandbox environment rules (this Docker topology,
#      the shared-directory path mapping, the SSH agent bridge) into the
#      guest's coding agents — opencode's global AGENTS.md and the Copilot
#      CLI's copilot-instructions.md, content from scripts/agent-rules.md
#      with the run's actual work-dir/mount paths substituted in and the
#      SSH agent section included only when the bridge is up. The runner
#      asks before installing or updating the rules; files the user
#      modified in the guest are only replaced after a confirmation that
#      defaults to no.
#   5. Offers to copy the host's user settings into the guest — the global
#      opencode config (json, tui, agents, commands, modes, plugins, skills,
#      tools, themes) + auth, the OpenCodeReview config
#      (~/.opencodereview/config.json), the Copilot CLI config + skills
#      (~/.copilot/config.json, ~/.copilot/skills/), the VS Code extensions
#      (~/.vscode/extensions) and user config (settings.json, keybindings,
#      snippets), ~/.ssh/allowed_signers, ~/.ssh/known_hosts,
#      ~/.ssh/*.sh, ~/.gitconfig (see docs/macos.md).
#      Runs once per guest: a versioned marker inside the guest tracks what
#      was copied, and bumping the settings version (in
#      scripts/lib/macos-settings.sh) re-copies when settings change.
#      OpenChamber is restarted after a copy so it picks up the new
#      settings. The same copy can be triggered on demand with
#      ./scripts/sync-macos-sandbox.sh.
#   6. Verifies that OpenChamber is up and offers to open it in the browser.
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
#   SANDBOX_DOCKER_PORT        TCP port for the Docker engine bridge (4101)
#   SANDBOX_OPENCHAMBER_PORT   guest port of OpenChamber (4000)
#   SANDBOX_CPU_COUNT          CPUs for a freshly cloned VM (8)
#   SANDBOX_MEMORY_MB          RAM for a freshly cloned VM, in MB (16384)
#   GHCR_OWNER                 GHCR owner for pulls (default: from git remote)
#   NO_COLOR                   disable colored output (any non-empty value)
#
# Requires tart (brew install cirruslabs/cli/tart); socat on the host
# (brew install socat) only when an SSH agent or Docker bridge is needed.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- configuration ----------------------------------------------------------

image=${SANDBOX_IMAGE:-sandbox-macos-tahoe}
vm=${SANDBOX_VM:-sandbox-macos}
work_dir=${SANDBOX_WORK_DIR:-/Volumes/dev}
mount_name=${SANDBOX_MOUNT_NAME:-dev}
agent_port=${SANDBOX_AGENT_PORT:-4100}
docker_port=${SANDBOX_DOCKER_PORT:-4101}
openchamber_port=${SANDBOX_OPENCHAMBER_PORT:-4000}
cpu_count=${SANDBOX_CPU_COUNT:-8}
memory_mb=${SANDBOX_MEMORY_MB:-16384}

headless=0
skip_agent=0
skip_settings=0
skip_docker=0
# Run 'tart run' in the background by default (the script exits, the VM keeps
# running). --foreground sets this to 0: the script blocks until the VM stops
# and Cmd+C in the terminal stops it too.
detached=1

tart_pid=
tart_log=
bridge_pid=
docker_bridge_pid=
vm_ip=
agent_bridged=0
guest_bridge_up=0
docker_bridged=0
docker_bridge_up=0
docker_engine_up=0
docker_server_version=
rules_state=
openchamber_up=0
settings_state=

# Shared helpers (colors, confirm, ...) and user-settings logic — also used
# by sync-macos-sandbox.sh. Keep the settings copy logic in the lib, not here.
. "$repo_root/scripts/lib/macos-settings.sh"

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

# Prints the host's gateway address on Tart's VM network: the host is always
# .1 on the shared /24 (see docs/ssh-agent.md). The VM's IP may only become
# available after its state flips to 'running' (see get_vm_ip), so a single
# 'tart ip' call can fail right after boot — retry it a few times before
# giving up, so a slow DHCP lease does not silently skip the bridges.
get_vm_gateway() {
    n=0
    while [ "$n" -lt 5 ]; do
        ip=$(get_vm_ip)
        if [ -n "$ip" ]; then
            printf '%s\n' "$ip" | awk -F. '{print $1"."$2"."$3".1"}'
            return 0
        fi
        n=$((n + 1))
        sleep 2
    done
    return 1
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

    registry="ghcr.io/$owner/$image"
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
        # Capture system shortcuts into the guest by default: while the VM
        # window is focused, Cmd+Space, Cmd+Tab, etc. trigger Spotlight and
        # the app switcher inside the guest instead of on the host.
        flags='--capture-system-keys --no-audio'
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

# --- step 3: SSH agent + Docker bridges (docs/ssh-agent.md, docs/macos.md) ---

# Makes sure socat is installed on the host, offering to install it via brew.
ensure_host_socat() {
    if command -v socat >/dev/null 2>&1; then
        return 0
    fi
    warn "socat is not installed on the host."
    if confirm "Install it with 'brew install socat' now?" y; then
        brew install socat || return 1
    else
        return 1
    fi
}

start_host_bridge() {
    sock="$1"

    ensure_host_socat || return 1

    if lsof -nP -iTCP:"$agent_port" -sTCP:LISTEN >/dev/null 2>&1; then
        ok "A listener is already bound to TCP port $agent_port — assuming the bridge is up."
        return 0
    fi

    # The host's address on Tart's VM network: every VM is on the same /24 and
    # the host is always .1 (see docs/ssh-agent.md). get_vm_gateway retries
    # the IP fetch — it can fail right after boot.
    gw=$(get_vm_gateway || true)
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

# --- step 3 (cont.): Docker engine bridge ------------------------------------
#
# The sandbox image ships the docker CLI but no engine (the guest can't run
# one — no nested virtualization for macOS guests, see docs/macos.md "Docker
# (remote engine)"). This bridges the host's engine socket into the guest
# exactly like the SSH agent bridge above: a host-side socat turns the engine
# socket into a TCP port on Tart's VM network for this run, and a guest-side
# socat (persisted in ~/.zprofile, auto-restarted on login) turns it back
# into a Unix socket at ~/.docker/run/docker.sock. A docker context 'host'
# pointing at that socket is created and made the default in the guest, so
# every docker invocation — shells, opencode, OpenChamber — hits the host
# engine. ~/.zprofile additionally exports DOCKER_HOST and
# TESTCONTAINERS_HOST_OVERRIDE (the NAT gateway), so docker clients that
# don't read contexts — e.g. testcontainers — still find the engine and
# reach its published ports from the guest.

# Prints the path of a Docker engine socket on the host, or nothing. Looks for
# the engines the sandbox supports: Docker Desktop (4.30+ keeps the socket at
# ~/.docker/run/docker.sock), Colima, OrbStack, and the legacy /var/run path.
find_host_docker_socket() {
    for sock in \
        "$HOME/.docker/run/docker.sock" \
        "$HOME/.colima/default/docker.sock" \
        "$HOME/.orbstack/run/docker.sock" \
        "/var/run/docker.sock"; do
        if [ -S "$sock" ]; then
            printf '%s\n' "$sock"
            return 0
        fi
    done
    return 1
}

start_host_docker_bridge() {
    sock="$1"

    ensure_host_socat || return 1

    if lsof -nP -iTCP:"$docker_port" -sTCP:LISTEN >/dev/null 2>&1; then
        ok "A listener is already bound to TCP port $docker_port — assuming the Docker bridge is up."
        return 0
    fi

    gw=$(get_vm_gateway || true)
    if [ -z "$gw" ]; then
        warn "could not determine the host gateway address ('tart ip $vm' failed)."
        return 1
    fi

    cmd "socat TCP-LISTEN:$docker_port,reuseaddr,fork,bind=$gw -> $sock"
    socat TCP-LISTEN:"$docker_port",reuseaddr,fork,bind="$gw" UNIX-CONNECT:"$sock" &
    docker_bridge_pid=$!
    sleep 1
    if kill -0 "$docker_bridge_pid" 2>/dev/null; then
        ok "Host Docker bridge is up (pid $docker_bridge_pid)."
        return 0
    fi
    warn "host Docker bridge exited immediately — check the engine socket path."
    docker_bridge_pid=
    return 1
}

# Persist the guest-side Docker bridge in the guest's ~/.zprofile: a socat
# auto-restart that recreates ~/.docker/run/docker.sock on every login (the
# socket is rebuilt after reboots; /tmp would be cleared, ~/.docker survives),
# plus DOCKER_HOST and TESTCONTAINERS_HOST_OVERRIDE exports so docker clients
# that don't read contexts (e.g. testcontainers) reach the host engine and
# its published ports from the guest. Each block is guarded by its own marker
# and appended independently, so guests set up before the env exports existed
# get them on the next run without duplicating the socat block. Idempotent.
persist_guest_docker() {
    if ! tart exec -i "$vm" sh -s "$docker_port" 2>/dev/null <<'GUEST_DOCKER_ZPROFILE'
port=$1
if ! grep -qF '# Docker bridge to the host' "$HOME/.zprofile" 2>/dev/null; then
    {
        printf '\n%s\n' '# Docker bridge to the host (host engine via socat, see docs/macos.md)'
        printf '%s\n' \
            'if ! pgrep -f "UNIX-LISTEN:$HOME/.docker/run/docker.sock" >/dev/null 2>&1 && command -v socat >/dev/null 2>&1; then' \
            '    mkdir -p "$HOME/.docker/run"' \
            "    HOST_GW=\$(netstat -nr | awk '/default/{print \$2; exit}')" \
            "    nohup socat UNIX-LISTEN:\"\$HOME/.docker/run/docker.sock\",fork,unlink-early,mode=600 TCP:\"\$HOST_GW\":$port >/dev/null 2>&1 &" \
            'fi'
    } >> "$HOME/.zprofile"
fi
if ! grep -qF '# Docker env vars for the host engine' "$HOME/.zprofile" 2>/dev/null; then
    {
        printf '\n%s\n' '# Docker env vars for the host engine (testcontainers support, see docs/macos.md)'
        printf '%s\n' \
            'export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"' \
            "export TESTCONTAINERS_HOST_OVERRIDE=\"\$(netstat -nr | awk '/default/{print \$2; exit}')\""
    } >> "$HOME/.zprofile"
fi
GUEST_DOCKER_ZPROFILE
    then
        warn "could not update the guest's ~/.zprofile (Docker bridge)."
    fi
}

# Returns 0 when the guest Docker bridge (socat block + env exports) is
# already persisted in the guest's ~/.zprofile.
guest_docker_installed() {
    tart exec "$vm" sh -c 'grep -qF "# Docker bridge to the host" "$HOME/.zprofile" 2>/dev/null && grep -qF "# Docker env vars for the host engine" "$HOME/.zprofile" 2>/dev/null' 2>/dev/null
}

# Start the guest bridge for this boot (survives the tart exec session) and
# report whether it is up.
ensure_guest_docker_bridge() {
    docker_guest_status=
    if ! docker_guest_status=$(tart exec -i "$vm" sh -s "$docker_port" 2>/dev/null <<'GUEST_DOCKER_BRIDGE'
port=$1
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p "$HOME/.docker/run"
sock="$HOME/.docker/run/docker.sock"
if ! pgrep -f "UNIX-LISTEN:$sock" >/dev/null 2>&1; then
    HOST_GW=$(netstat -nr | awk '/default/{print $2; exit}')
    nohup socat UNIX-LISTEN:"$sock",fork,unlink-early,mode=600 \
        TCP:"$HOST_GW":$port >/dev/null 2>&1 &
fi
sleep 1
if pgrep -f "UNIX-LISTEN:$sock" >/dev/null 2>&1; then
    echo docker-bridge-up
else
    echo docker-bridge-failed
fi
GUEST_DOCKER_BRIDGE
); then
        docker_guest_status=docker-bridge-failed
    fi

    case "$docker_guest_status" in
        docker-bridge-up)
            docker_bridge_up=1
            ok "Guest Docker bridge is up: ~/.docker/run/docker.sock -> host TCP $docker_port"
            ;;
        *)
            warn "guest Docker bridge did not start — is socat present in the guest?"
            ;;
    esac
}

# Point the guest's docker CLI at the bridged socket: create (or update) the
# 'host' context and make it the default. Contexts live in the guest's
# ~/.docker/config.json, so this survives reboots and applies to every docker
# invocation, not just login shells.
ensure_guest_docker_context() {
    if ! tart exec -i "$vm" sh -s 2>/dev/null <<'GUEST_DOCKER_CONTEXT'
export PATH="/opt/homebrew/bin:$PATH"
sock="$HOME/.docker/run/docker.sock"
if docker context inspect host >/dev/null 2>&1; then
    docker context update host --docker "host=unix://$sock" >/dev/null 2>&1
else
    docker context create host --docker "host=unix://$sock" >/dev/null 2>&1
fi
docker context use host >/dev/null 2>&1 || exit 1
# Validate the context (its exit code is this script's exit code) without
# leaking the raw inspect output into the runner's console.
docker context inspect host --format '{{.Name}} {{.Endpoints.docker.Host}}' >/dev/null
GUEST_DOCKER_CONTEXT
    then
        # The `if !` above: this branch runs when tart exec fails.
        warn "could not set up the guest docker context — is the docker CLI in the image?"
        warn "images built before the Docker CLI landed lack it; pull a current image and re-clone."
    else
        ok "Guest docker context 'host' -> ~/.docker/run/docker.sock (default)."
    fi
}

# End-to-end check: can the guest's docker CLI reach the host engine through
# the bridge? Prints the engine's server version, or 'unreachable'. Retries
# briefly — Docker Desktop may still be starting its VM.
verify_guest_docker() {
    if ! tart exec -i "$vm" sh -s 2>/dev/null <<'GUEST_DOCKER_VERIFY'
export PATH="/opt/homebrew/bin:$PATH"
n=0
while [ "$n" -lt 15 ]; do
    v=$(docker info --format '{{.ServerVersion}}' 2>/dev/null) && { printf '%s\n' "$v"; exit 0; }
    n=$((n + 1))
    sleep 1
done
echo unreachable
GUEST_DOCKER_VERIFY
    then
        printf '%s\n' unreachable
    fi
}

setup_docker_bridge() {
    sock=
    if ! sock=$(find_host_docker_socket); then
        sock=
    fi
    if [ -z "$sock" ]; then
        info "No Docker engine socket found on the host (Docker Desktop, Colima, OrbStack)."
        info "Start an engine on the host and re-run to bridge it into the guest."
        return 0
    fi

    ok "Host Docker engine socket found: $sock"
    info "Bridging it into '$vm' on TCP port $docker_port."

    if ! start_host_docker_bridge "$sock"; then
        warn "skipping the Docker bridge."
        return 0
    fi
    docker_bridged=1

    # The guest side is persisted inside the guest (~/.zprofile + docker
    # context) — only offer to set it up when it isn't already there. Either
    # way, make sure the bridge runs and the context is set for this boot.
    if guest_docker_installed; then
        info "Guest Docker bridge is already set up in the guest's ~/.zprofile."
        ensure_guest_docker_bridge
        ensure_guest_docker_context
    elif confirm "Set up the Docker bridge inside the guest too (guest socat + docker context 'host' + env exports)?" y; then
        persist_guest_docker
        ensure_guest_docker_bridge
        ensure_guest_docker_context
    else
        info "Guest Docker bridge not configured — docker in the guest will not reach the host engine."
    fi

    if [ "$docker_bridge_up" = 1 ]; then
        docker_server_version=$(verify_guest_docker)
        if [ -n "$docker_server_version" ] && [ "$docker_server_version" != unreachable ]; then
            docker_engine_up=1
            ok "Docker engine is reachable from the guest (server version $docker_server_version)."
        else
            warn "Docker engine not reachable from the guest yet — is it running on the host?"
            warn "The bridge reconnects on its own once it is; re-run this script to re-check."
        fi
    fi
}

# --- step 3 (cont.): agent rules ---------------------------------------------
#
# Installs the sandbox environment rules into the guest's coding agents:
# opencode's global rules (~/.config/opencode/AGENTS.md) and the Copilot
# CLI's personal instructions (~/.copilot/copilot-instructions.md). The
# content ships in the repo (scripts/agent-rules.md) and explains the
# runtime topology this script establishes — the Docker remote-engine
# bridge (context 'host', published ports via the NAT gateway, volume
# mounts needing host paths), the shared-directory path mapping, and the
# SSH agent bridge — so agents stop guessing at localhost ports and guest
# paths. The {{...}} path placeholders are substituted from the actual run
# settings (SANDBOX_WORK_DIR / SANDBOX_MOUNT_NAME), and the SSH agent
# section is dropped unless the agent bridge is actually up — the rules
# never claim a bridge that is not running.
#
# The rules are refreshed on every run, but never written without asking:
# the probe below only inspects the guest and reports what would change
# (install / update / conflict / uptodate), and the host confirms before
# any write. A checksum marker in ~/.config/agent-sandbox/ tracks what the
# runner installed, so files the user modified are only replaced after a
# separate confirmation that defaults to no. Idempotent; safe to run on
# every run.

install_agent_rules() {
    agent_rules_src="$repo_root/scripts/agent-rules.md"
    if [ ! -f "$agent_rules_src" ]; then
        warn "agent rules file not found: $agent_rules_src"
        return 0
    fi

    # Read-only guest-side probe: compares each target against the new
    # content and the marker, without writing anything. Reports the most
    # significant pending action: conflict (user-modified file) > install
    # (missing file) > update (file we installed, content changed) >
    # uptodate (nothing to do).
    rules_probe=$(cat <<'GUEST_RULES_PROBE'
tmp=$(mktemp) || exit 1
trap "rm -f $tmp" EXIT
cat > "$tmp" || exit 1
marker="$HOME/.config/agent-sandbox/agent-rules.sha256"
prev=$(cat "$marker" 2>/dev/null || true)
new_sha=$(shasum -a 256 "$tmp" | cut -d' ' -f1)
conflict=0
install=0
update=0
for target in \
    "$HOME/.config/opencode/AGENTS.md" \
    "$HOME/.copilot/copilot-instructions.md"; do
    if [ ! -f "$target" ]; then
        install=1
    elif [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$new_sha" ]; then
        : # already current
    elif [ -n "$prev" ] && \
        [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$prev" ]; then
        update=1
    else
        conflict=1
    fi
done
if [ "$conflict" = 1 ]; then
    printf "%s\n" conflict
elif [ "$install" = 1 ]; then
    printf "%s\n" install
elif [ "$update" = 1 ]; then
    printf "%s\n" update
else
    printf "%s\n" uptodate
fi
GUEST_RULES_PROBE
)

    # Guest-side overwrite, used only after the user confirmed: replaces
    # both files and refreshes the marker.
    rules_force=$(cat <<'GUEST_RULES_FORCE'
tmp=$(mktemp) || exit 1
trap "rm -f $tmp" EXIT
cat > "$tmp" || exit 1
for target in \
    "$HOME/.config/opencode/AGENTS.md" \
    "$HOME/.copilot/copilot-instructions.md"; do
    mkdir -p "$(dirname "$target")"
    cp "$tmp" "$target" || exit 1
done
mkdir -p "$HOME/.config/agent-sandbox"
printf "%s\n" "$(shasum -a 256 "$tmp" | cut -d' ' -f1)" \
    > "$HOME/.config/agent-sandbox/agent-rules.sha256"
printf "%s\n" overwritten
GUEST_RULES_FORCE
)

    guest_mount="/Volumes/My Shared Files/$mount_name"
    content=$(sed -e "s|{{HOST_WORK_DIR}}|$work_dir|g" \
        -e "s|{{GUEST_MOUNT}}|$guest_mount|g" "$agent_rules_src" |
        {
            if [ "$agent_bridged" = 1 ] && [ "$guest_bridge_up" = 1 ]; then
                cat
            else
                sed '/^## SSH agent bridge$/,$d'
            fi
        }) || {
        rules_state=failed
        warn "could not render the agent rules."
        return 1
    }

    rules_state=
    if ! rules_state=$(printf '%s\n' "$content" |
        tart exec -i "$vm" sh -c "$rules_probe" 2>/dev/null); then
        rules_state=failed
        warn "could not inspect the agent rules in the guest."
        return 1
    fi

    case "$rules_state" in
        install | update)
            if confirm "Install/update the sandbox agent rules in the guest?" y; then
                if printf '%s\n' "$content" |
                    tart exec -i "$vm" sh -c "$rules_force" >/dev/null 2>&1; then
                    if [ "$rules_state" = install ]; then
                        rules_state=installed
                    else
                        rules_state=updated
                    fi
                    ok "Installed/updated the sandbox agent rules (opencode + Copilot CLI)."
                else
                    rules_state=failed
                    warn "could not install the agent rules into the guest."
                fi
            else
                rules_state=kept
                info "Keeping the guest's agent rules as they are."
            fi
            ;;
        conflict)
            info "The guest has its own agent rules."
            if confirm "Overwrite the guest's agent rules with the sandbox rules?" n; then
                if printf '%s\n' "$content" |
                    tart exec -i "$vm" sh -c "$rules_force" >/dev/null 2>&1; then
                    rules_state=overwritten
                    ok "Overwrote the guest's agent rules."
                else
                    rules_state=failed
                    warn "could not overwrite the agent rules in the guest."
                fi
            else
                rules_state=kept
                info "Keeping the guest's own agent rules."
            fi
            ;;
        *)
            rules_state=uptodate
            info "Agent rules are up to date in the guest."
            ;;
    esac
}

# --- step 4: user settings ----------------------------------------------------
#
# Copies the host's user settings into the guest: opencode config, skills,
# commands and auth, the OpenCodeReview config (~/.opencodereview/config.json),
# Copilot config + skills (~/.copilot), VS Code extensions
# (~/.vscode/extensions) and user config (settings.json/keybindings/snippets
# under ~/Library/Application Support/Code/User/), ~/.ssh/allowed_signers,
# ~/.ssh/known_hosts, ~/.ssh/*.sh and ~/.gitconfig. The copy logic lives in
# scripts/lib/macos-settings.sh (shared with sync-macos-sandbox.sh); this
# section is the runner's flow
# around it. Runs once per guest — a versioned marker file inside the guest
# (~/.config/agent-sandbox/settings-copied) records which settings version
# was copied; guests with an older marker are offered the copy again, so
# bumping $settings_version in the lib re-runs the step when new settings
# are added.

setup_user_settings() {
    if guest_settings_installed; then
        ok "User settings are already in the guest (version $settings_version) — skipping."
        settings_state=uptodate
        return 0
    fi

    settings_list=$(collect_settings_files)
    if [ -z "$settings_list" ]; then
        info "No user settings found on the host (opencode config and auth, OpenCodeReview config, Copilot config, VS Code config and extensions, ~/.ssh, ~/.gitconfig) — nothing to copy."
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

    if ! printf '%s\n' "$settings_list" | copy_settings_to_guest; then
        settings_state=failed
        return 1
    fi

    count=$(printf '%s\n' "$settings_list" | wc -l | tr -d ' ')
    settings_state=copied
    ok "Copied $count item(s) into the guest."
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
    if [ "$headless" = 0 ]; then
        printf '    %-12s %s\n' 'Keys:' 'system shortcuts go to the guest while the window is focused'
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
    if [ "$docker_bridged" = 1 ]; then
        if [ "$docker_engine_up" = 1 ]; then
            printf '    %-12s %s\n' 'Docker:' "${c_green}host engine (v$docker_server_version) -> TCP $docker_port -> guest (context 'host')${c_reset}"
        elif [ "$docker_bridge_up" = 1 ]; then
            printf '    %-12s %s\n' 'Docker:' "${c_yellow}bridge up, engine not reachable in the guest — is Docker running on the host?${c_reset}"
        else
            printf '    %-12s %s\n' 'Docker:' "${c_yellow}host bridge up (TCP $docker_port), guest bridge not running${c_reset}"
        fi
    else
        printf '    %-12s %s\n' 'Docker:' 'not bridged'
    fi
    case "$rules_state" in
        installed)
            printf '    %-12s %s\n' 'Agent rules:' "${c_green}installed for opencode + Copilot${c_reset}"
            ;;
        updated | overwritten)
            printf '    %-12s %s\n' 'Agent rules:' "${c_green}updated for opencode + Copilot${c_reset}"
            ;;
        uptodate)
            printf '    %-12s %s\n' 'Agent rules:' 'up to date in the guest'
            ;;
        kept)
            printf '    %-12s %s\n' 'Agent rules:' 'guest rules kept (not overwritten)'
            ;;
        failed)
            printf '    %-12s %s\n' 'Agent rules:' "${c_yellow}could not be installed${c_reset}"
            ;;
        *)
            printf '    %-12s %s\n' 'Agent rules:' 'not installed'
            ;;
    esac
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
        stop_hint="run ./scripts/stop-macos-sandbox.sh"
    elif [ "$headless" = 1 ]; then
        stop_hint="run ./scripts/stop-macos-sandbox.sh in another terminal"
    elif [ -n "$tart_pid" ]; then
        stop_hint="press Cmd+C in this terminal, or run ./scripts/stop-macos-sandbox.sh in another terminal"
    else
        stop_hint="run ./scripts/stop-macos-sandbox.sh"
    fi
    printf '    %-12s %s\n' 'Stop:' "$stop_hint"
    if [ "$detached" = 1 ] && [ -n "$tart_pid" ]; then
        printf '    %-12s %s\n' 'Background:' "VM keeps running after this script exits (tart log: $tart_log)"
        if [ "$agent_bridged" = 1 ]; then
            printf '    %-12s %s\n' 'Bridge:' "host socat listener on TCP $agent_port stays up — stop it with: ./scripts/stop-macos-sandbox.sh"
        fi
        if [ "$docker_bridged" = 1 ]; then
            printf '    %-12s %s\n' 'Bridge:' "host Docker socat listener on TCP $docker_port stays up — stop it with: ./scripts/stop-macos-sandbox.sh"
        fi
    fi
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: run-macos-sandbox.sh [options]

Pulls (if needed), runs, and wires up a macOS sandbox VM.

By default the VM runs in the background: the script exits after the summary
and the VM keeps running (stop it later with ./scripts/stop-macos-sandbox.sh;
tart output goes to ~/Library/Logs/agent-sandbox/tart-<vm>.log).

Options:
  --headless     Run without a window (tart run --no-graphics)
  --foreground   Keep the terminal attached and block until the VM stops
                 (Cmd+C in the terminal stops the VM)
  --no-agent     Skip the SSH agent bridge setup
  --no-docker    Skip the Docker engine bridge setup
  --no-settings  Skip copying the host's user settings into the guest
  -h, --help     Show this help

Environment:
  SANDBOX_IMAGE              image VM to pull/clone from (sandbox-macos-tahoe)
  SANDBOX_VM                 working VM name (sandbox-macos)
  SANDBOX_WORK_DIR           host dir to share ( /Volumes/dev ; empty = no share)
  SANDBOX_MOUNT_NAME         mount name inside the guest (dev)
  SANDBOX_AGENT_PORT         TCP port for the SSH agent bridge (4100)
  SANDBOX_DOCKER_PORT        TCP port for the Docker engine bridge (4101)
  SANDBOX_OPENCHAMBER_PORT   guest port of OpenChamber (4000)
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
        --no-docker) skip_docker=1 ;;
        --no-settings) skip_settings=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

command -v tart >/dev/null 2>&1 ||
    die "tart is not installed — run 'brew install cirruslabs/cli/tart' first."

# Stop the host socat bridges (SSH agent + Docker) on exit, but only in
# foreground mode and only when this script launched the VM itself. In
# background mode the VM (and its need for the bridges) outlives this script,
# so the bridges must stay up — and when the VM was already running the script
# exits right after the bridge setup for the same reason. The host bridges are
# never persisted; the guest sides are (see persist_guest_agent and
# persist_guest_docker). Re-running the script is idempotent — see the port
# checks in start_host_bridge / start_host_docker_bridge.
cleanup() {
    if [ "$detached" = 0 ] && [ -n "$docker_bridge_pid" ] && [ -n "$tart_pid" ]; then
        kill "$docker_bridge_pid" 2>/dev/null || true
        info "Stopped the host Docker bridge (pid $docker_bridge_pid)."
    fi
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

# 3. Host bridges: SSH agent + Docker engine (host side per run; the guest
#    sides are persisted inside the guest — ~/.zprofile, docker context).
step "Step 3/5: Host bridges (SSH agent, Docker)"
if [ "$skip_agent" = 1 ]; then
    info "Skipping SSH agent bridge setup (--no-agent)."
else
    setup_ssh_agent
fi
if [ "$skip_docker" = 1 ]; then
    info "Skipping Docker bridge setup (--no-docker)."
else
    setup_docker_bridge
fi
install_agent_rules

# 4. User settings (opencode config + auth, Copilot config + skills, VS Code
#    config + extensions, SSH/Git dotfiles) — copied once per guest, tracked
#    by a versioned marker inside the guest.
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
