#!/bin/bash
#
# run-ubuntu-vmware-sandbox.sh — run and wire up an Ubuntu 24.04 (ARM64)
# sandbox VM under VMware Fusion.
#
# Usage:
#   ./scripts/run-ubuntu-vmware-sandbox.sh [--headless] [--foreground]
#                                           [--no-agent] [--no-docker]
#                                           [--no-settings]
#                                           [--work-dir PATH] [--reset]
#
# The Ubuntu VMware sandbox is a .vmx + .vmdk VM (built by
# images/ubuntu-arm64-vmware/, published to GHCR as a tar.gz), not a Tart
# VM — so like run-windows-vmware-sandbox.sh this script drives vmrun
# directly. What it does:
#
#   1. Picks the VM archive: $UBUNTU_VMWARE_IMAGE if set, else the local
#      build output (build/ubuntu-arm64-vmware/output/
#      sandbox-ubuntu-24-04-arm64-vmware.tar.gz, created on demand), else pulls
#      sandbox-ubuntu-24-04-arm64-vmware:latest from GHCR via oras (asks first).
#      The pristine VM is never written to: the archive is extracted into
#      ~/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware/
#      and a full clone becomes the working VM, so the working VM survives
#      reboots of the guest and reruns of this script — until the archive
#      changes: a rebuild or re-pull is detected by the archive's size +
#      mtime (not its path, which stays the same), and the base + working
#      clone are recreated. --reset deletes the working state and starts
#      from the pristine clone. The clone is
#      upgraded in place to the hardware version the installed Fusion
#      supports (vmrun upgradevm, shared helper scripts/lib/vmware.sh — the
#      image builds at hardware version 20 and a newer Fusion would prompt
#      once on the first GUI start); recorded in .hw-version so it runs
#      once per clone.
#   2. Boots the working VM with vmrun (headless or in a Fusion window).
#      No port forwarding: the VM sits on Fusion's NAT network (vmnet8)
#      and the host is that network's router, so SSH (22) and OpenChamber
#      (4000) are reachable directly at the guest IP that vmrun
#      getGuestIPAddress reports (open-vm-tools in the image provide it).
#      By default the VM keeps running after the script exits (log summary
#      at the end); --foreground also blocks until the VM stops.
#   3. Bridges the host's SSH agent into the guest when SSH_AUTH_SOCK is
#      overridden by a password manager (see docs/ssh-agent.md): a host-side
#      socat turns the agent socket into TCP port 4400 on the host's
#      vmnet8 address (reachable from the guest at that IP), and a
#      guest-side systemd user service (rendered from
#      scripts/lib/ubuntu-vmware/guest-setup.sh) presents it as a Unix
#      socket at /tmp/ssh-agent.sock. The guest side is persisted as a
#      systemd user service (linger is enabled in the image) and
#      auto-starts; the host side only lives for this run.
#   4. Bridges the host's Docker engine the same way when one is running
#      (Docker Desktop, Colima, OrbStack, ...): host socat on TCP 4401,
#      guest socket /tmp/docker.sock, DOCKER_HOST exported in
#      /etc/profile.d/agent-sandbox.sh, so `docker` and `docker compose`
#      in the guest hit the host engine. --no-docker skips.
#   5. Optionally shares a host directory into the guest (--work-dir PATH,
#      HGFS via open-vm-tools; visible as /mnt/hgfs/work in the guest).
#   6. Installs the sandbox agent rules (scripts/agent-rules-linux.md)
#      into the guest's coding agents — opencode's global AGENTS.md and
#      the Copilot CLI's copilot-instructions.md.
#   7. Copies the host's user settings into the guest — the global opencode
#      config + auth, the OpenCodeReview config, the Copilot CLI config +
#      skills, the VS Code extensions + user config, ~/.ssh files and
#      ~/.gitconfig (see docs/ubuntu-vmware.md). Runs once per VM: a
#      versioned marker inside the guest (~/.config/agent-sandbox/
#      settings-copied) records which settings version was copied, and
#      bumping the settings version (in scripts/lib/ubuntu-vmware/
#      settings.sh) re-copies when the settings change. --no-settings
#      skips. The same copy can be triggered on demand with
#      scripts/sync-ubuntu-vmware-sandbox.sh.
#   8. Verifies that OpenChamber answers on http://<guest-ip>:4000 and
#      offers to open it in the browser.
#
# Environment (defaults in parentheses):
#   UBUNTU_VMWARE_IMAGE   path to a local sandbox-ubuntu-24-04-arm64-vmware.tar.gz
#                         to run instead of the discovered/pulled one
#   SANDBOX_STATE_DIR      working VM state dir
#                          (~/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware)
#   UBUNTU_PASSWORD        admin password in the guest (read from the
#                          image's vars file; override after changing it
#                          in the guest)
#   SANDBOX_OPENCHAMBER_PORT guest port of OpenChamber (4000)
#   SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4400)
#   SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4401)
#   GHCR_OWNER             GHCR owner for pulls (default: from git remote)
#   NO_COLOR               disable colored output (any non-empty value)
#
# Requires: Apple Silicon Mac, VMware Fusion (free for personal use),
# oras (brew install oras) only when pulling the image from GHCR, socat on
# the host (brew install socat) only when a bridge is needed, and expect
# (ships with macOS) for guest-side setup over SSH.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- configuration ----------------------------------------------------------

image_name=sandbox-ubuntu-24-04-arm64-vmware
platform_dir="$repo_root/images/ubuntu-arm64-vmware"
vars_file="$platform_dir/vars/${image_name}.pkrvars.hcl"
host_state_dir="${SANDBOX_STATE_DIR:-$HOME/Library/Application Support/agent-sandbox/ubuntu-24-04-arm64-vmware}"
# The working clone's display name in Fusion's VM library. `vmrun clone`
# inherits the source vmx's displayName ("sandbox-ubuntu-24-04-arm64-vmware"), so
# without a rename the working VM would be indistinguishable from the
# pristine base (both would show under the base's name).
vm_display_name="agent-sandbox-ubuntu-24-04-arm64-vmware"
agent_port=${SANDBOX_AGENT_PORT:-4400}
docker_port=${SANDBOX_DOCKER_PORT:-4401}
openchamber_port=${SANDBOX_OPENCHAMBER_PORT:-4000}
guest_port=22

headless=0
detached=1
skip_agent=0
skip_docker=0
skip_settings=0
reset_vm=0
work_dir=""

work_vmx=
guest_ip=
host_alias=
bridge_pid=
docker_bridge_pid=
agent_bridged=0
guest_bridge_up=0
docker_bridged=0
docker_bridge_up=0
docker_engine_up=0
docker_server_version=
openchamber_up=0
settings_state=

# Deterministic state-dir paths (stop_running_vm needs them before any
# state is created).
base_dir="$host_state_dir/base"
base_marker="$host_state_dir/base-archive.txt"
base_vmx="$base_dir/${image_name}.vmx"
work_vmx="$host_state_dir/working/${image_name}.vmx"

# --- shared library ---------------------------------------------------------
#
# scripts/lib/vmware.sh: vmrun resolution (PATH > Fusion app bundle) and the
# VM hardware-version upgrade (post-build + working-clone step; see
# upgrade_working_vm below).

library_dir="$repo_root/scripts/lib/ubuntu-vmware"
# shellcheck source=scripts/lib/vmware.sh
source "$repo_root/scripts/lib/vmware.sh"

# scripts/lib/ubuntu-vmware/settings.sh: the host user-settings copy logic
# (shared with scripts/sync-ubuntu-vmware-sandbox.sh). Uses $guest_ip,
# $guest_user and $guest_password, which are set below — the functions are
# only definitions until then.
# shellcheck source=scripts/lib/ubuntu-vmware/settings.sh
source "$repo_root/scripts/lib/ubuntu-vmware/settings.sh"

# --- output helpers (same conventions as the other runners) ------------------

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

# --- vars file helpers ------------------------------------------------------

# Same sed pattern as scripts/build.sh: pulls a quoted string variable out
# of the vars file.
read_var() {
    sed -n \
        "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\"[[:space:]]*$/\1/p" \
        "$vars_file" 2>/dev/null | head -n1
}

# Per-image build directory, mirroring images/ubuntu-arm64-vmware/build.sh:
# the local build output fallback lives in build/ubuntu-arm64-vmware/.
build_dir="$repo_root/build/ubuntu-arm64-vmware"

# --- step 1: prerequisites --------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command '$1' not found on PATH. Install with: $2"
}

ensure_prereqs() {
    [ "$(uname -s)" = "Darwin" ] || die "this script runs on macOS only."
    [ "$(uname -m)" = "arm64" ] || die "Apple Silicon required (VMware Fusion cannot virtualize ARM64 guests on Intel)."
    [ -n "$vmrun_bin" ] ||
        die "vmrun not found — install VMware Fusion (free for personal use) or set FUSION_APP_PATH."
    require_cmd curl   "comes with macOS"
    require_cmd expect "comes with macOS"
    command -v socat >/dev/null 2>&1 ||
        warn "socat is not installed (brew install socat) — SSH agent and Docker bridges will be skipped."
}

# --- step 2: image selection ------------------------------------------------

# Prints the path of the tar.gz to run, pulling it when needed. The
# pristine VM is only ever read (the working VM is a full clone).
pick_image() {
    if [ -n "${UBUNTU_VMWARE_IMAGE:-}" ]; then
        [ -f "$UBUNTU_VMWARE_IMAGE" ] || die "UBUNTU_VMWARE_IMAGE points to a file that does not exist: $UBUNTU_VMWARE_IMAGE"
        printf '%s\n' "$UBUNTU_VMWARE_IMAGE"
        return 0
    fi

    local_output="$build_dir/output/${image_name}.tar.gz"
    if [ -f "$build_dir/output/${image_name}.vmx" ] && [ ! -f "$local_output" ]; then
        # stdout is the contract (the image path); diagnostics go to stderr.
        printf '%s\n' "    No archive yet — packing the local build output into $local_output" >&2
        (cd "$build_dir/output" &&
            tar -czf "$local_output" --exclude='*.log' \
                "${image_name}.vmx" "${image_name}.nvram" *.vmdk) ||
            die "failed to pack the local build output."
    fi
    if [ -f "$local_output" ]; then
        printf '%s\n' "$local_output"
        return 0
    fi

    owner=${GHCR_OWNER:-}
    if [ -z "$owner" ]; then
        owner=$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null |
            sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#/[^/]*$##')
    fi
    [ -n "$owner" ] || die "no GHCR owner — cannot pull. Set GHCR_OWNER, e.g. GHCR_OWNER=my-org."

    registry="ghcr.io/$owner/$image_name"
    cached="$host_state_dir/image/${image_name}.tar.gz"
    if [ -f "$cached" ]; then
        printf '%s\n' "$cached"
        return 0
    fi

    command -v oras >/dev/null 2>&1 ||
        die "oras is not installed — needed to pull $registry:latest (brew install oras). Set UBUNTU_VMWARE_IMAGE to a local archive to skip."
    if confirm "Pull $registry:latest (one-time, ~15 GB download)?" y; then
        mkdir -p "$host_state_dir/image"
        (cd "$host_state_dir/image" && oras pull "$registry:latest") ||
            die "oras pull failed — check your network connection (public GHCR images pull without a login)."
        [ -f "$cached" ] || die "oras pull produced no $cached — is the image published under $registry?"
        printf '%s\n' "$cached"
    else
        die "aborted — no sandbox image available. Set UBUNTU_VMWARE_IMAGE to a local archive or pull manually."
    fi
}

# --- step 3: working VM state (extracted base + full clone) -----------------

# Extracts the pristine archive into the state dir (once per archive) and
# clones a working VM from it. The base is never written to; the clone is
# the sandbox. When the archive changes (new build/pull), both are
# recreated — "changes" is detected by the archive's path + size + mtime
# (a rebuild packs a new image over the same path, so the path alone
# would never notice it), not the path alone.
ensure_base() {
    if [ "$reset_vm" = 1 ]; then
        info "Resetting the working VM (--reset) — deleting the extracted base and the working clone."
        rm -rf "$host_state_dir"
    fi

    # Identity of the pristine archive: path + size + mtime (same scheme as
    # the QEMU runner's backing-image marker). A rebuild packs the new
    # image at the SAME path, and `oras pull` overwrites the cached archive
    # in place too — comparing only the path would keep the old extracted
    # base and working clone running a stale image (observed: a
    # desktop-less VM kept booting after a rebuild that added the GNOME
    # desktop, because the marker still matched the old archive's path).
    archive_id="$image_archive|$(stat -f '%z' "$image_archive")|$(stat -f '%m' "$image_archive")"

    if [ -f "$base_marker" ] && [ "$(cat "$base_marker")" != "$archive_id" ]; then
        warn "The archive changed (new build or pull) — re-extracting the pristine VM and dropping the working clone."
        warn "The working clone's guest state (installs, config, agent files) is lost with it."
        rm -rf "$base_dir" "$host_state_dir/working"
    fi

    if [ -f "$base_marker" ] && [ "$(cat "$base_marker")" = "$archive_id" ] &&
        [ -f "$base_vmx" ]; then
        ok "Pristine VM extracted ($base_dir)."
        return 0
    fi

    mkdir -p "$base_dir"
    cmd "tar -xzf $image_archive -C $base_dir"
    tar -xzf "$image_archive" -C "$base_dir"
    printf '%s\n' "$archive_id" >"$base_marker"
    [ -f "$base_vmx" ] || die "archive extraction produced no $base_vmx (is the archive valid?)"
    ok "Pristine VM extracted ($base_vmx)."
}

ensure_working_vm() {
    if [ -f "$work_vmx" ]; then
        ok "Working VM exists ($work_vmx)."
        return 0
    fi

    mkdir -p "$(dirname "$work_vmx")"
    cmd "vmrun -T fusion clone $base_vmx $work_vmx full"
    vmrun clone "$base_vmx" "$work_vmx" full || {
        warn "full clone failed (Fusion may have rejected the destination path)."
        return 1
    }
    # The clone inherited the base's displayName — give it a distinct name
    # before the first start, so it shows as its own VM in Fusion's library.
    cmd "set displayName \"$vm_display_name\" in $work_vmx"
    if ! set_vm_display_name "$work_vmx" "$vm_display_name"; then
        warn "could not set the working VM's display name (Fusion will show the base's name)."
    fi
    ok "Working VM cloned ($work_vmx; display name '$vm_display_name')."
}

# Upgrades the working VM to the hardware version the installed Fusion
# supports (the version Fusion writes for a new VM). The image is built at
# hardware version 20 — the vmware-iso builder's level — and starting such
# a VM under a newer Fusion shows a one-time "Upgrade this virtual
# machine?" prompt on the first GUI (Fusion window) start; headless vmrun
# starts are unaffected. build.sh upgrades the artifact the same way
# (post-build), but the upgrade must happen on the clone too: the pristine
# base stays untouched, and artifacts built by older Fusion versions get
# upgraded here. A no-op upgradevm hangs ~3 min, so the result is recorded
# in .hw-version next to the vmx and the upgrade only runs once per VM
# version.
upgrade_working_vm() {
    local marker="$host_state_dir/working/.hw-version"
    local before after
    before=$(vmware_hw_version "$work_vmx") || before=""
    if [ -z "$before" ]; then
        return 0
    fi
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$before" ]; then
        return 0
    fi
    after=$(upgrade_vm_hardware "$work_vmx" "working VM" || printf '%s' "$before")
    printf '%s\n' "$after" >"$marker"
    if [ "$after" != "$before" ]; then
        ok "Working VM upgraded to hardware version $after (the installed Fusion's current)."
    fi
}

# --- step 4: boot the VM ----------------------------------------------------

# Stops a VM left running by a previous (detached) run. Must run before
# --reset and before a fresh boot — the old VM holds the clone's disks.
stop_running_vm() {
    if [ -z "$work_vmx" ]; then
        return 0
    fi
    if vmrun list 2>/dev/null | grep -q "$work_vmx"; then
        if ! confirm "The sandbox VM is already running — restart it?" n; then
            die "aborted — the VM is already running. Stop it with 'vmrun -T fusion stop' and re-run."
        fi
        cmd "vmrun -T fusion stop $work_vmx"
        vmrun stop "$work_vmx" || true
        n=0
        printf '%s' "    Waiting for the VM to stop"
        while vmrun list 2>/dev/null | grep -q "$work_vmx" && [ "$n" -lt 60 ]; do
            printf '.'
            sleep 2
            n=$((n + 1))
        done
        printf ' %s\n' "${c_green}stopped${c_reset}"
        sleep 1
    fi
}

launch_vm() {
    cmd "vmrun -T fusion start $work_vmx $( [ "$headless" = 1 ] && echo nogui || echo gui )"
    vmrun start "$work_vmx" "$([ "$headless" = 1 ] && echo nogui || echo gui)"
    ok "VM started."
}

# Waits for the guest IP (open-vm-tools report it — the image installs
# them). vmrun's getGuestIPAddress has no timeout, so poll with the perl
# alarm wrapper (macOS vmrun/curl have been observed to hang past their
# own timeouts; alarm kills them no matter what).
wait_guest_ip() {
    n=0
    printf '%s' "    Waiting for the guest IP (open-vm-tools; up to 15 min)"
    while [ "$n" -lt 180 ]; do
        ip=$(perl -e 'alarm 30; exec @ARGV' vmrun -T fusion getGuestIPAddress "$work_vmx" 2>/dev/null | tail -n1) || true
        # Strict: a dotted-quad only — getGuestIPAddress returns an error
        # message ("The VMware Tools are not running…") before the tools
        # finish starting, and that text must never become the guest IP.
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [ "$ip" != "0.0.0.0" ]; then
            printf ' %s\n' "${c_green}done${c_reset}"
            guest_ip=$ip
            return 0
        fi
        n=$((n + 1))
        printf '.'
        sleep 5
    done
    printf ' %s\n' "${c_yellow}failed${c_reset}"
    die "timed out waiting for the guest IP — are open-vm-tools running in the guest? (vmrun -T fusion list to check the VM)"
}

# Waits until the guest's sshd answers the BatchMode probe — ssh answers
# "Permission denied" when the server is up, "Connection refused" before.
# Output goes into a variable, not a pipe: grep -q would close the pipe on
# match, ssh would die of SIGPIPE (141), and pipefail would turn the probe
# into a failure.
wait_for_sshd() {
    label="$1"
    max="$2"

    ssh_ready() {
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -p "$guest_port" "$guest_user@$guest_ip" true 2>&1) || true
        case "$out" in
            *"Permission denied"*) return 0 ;;
        esac
        return 1
    }

    n=0
    printf '%s' "    Waiting for $label (up to $((max * 4 / 60)) min)"
    while [ "$n" -lt "$max" ]; do
        if ssh_ready; then
            printf ' %s\n' "${c_green}done${c_reset}"
            return 0
        fi
        n=$((n + 1))
        printf '.'
        sleep 4
    done
    printf ' %s\n' "${c_yellow}failed${c_reset}"
    die "timed out waiting for $label (no SSH on $guest_ip:$guest_port)."
}

# --- guest shell ------------------------------------------------------------

# Runs a remote command in the guest via SSH (expect drives the password
# prompt — macOS ships expect; sshpass does not exist). The command is a
# plain shell string; pieces of a script can be base64-encoded (no quotes
# or newlines once unwrapped) to keep the exec-request quoting sane.
# stdin passes through to the remote command (useful for `cat >`).
#
# Optional $2 sentinel: when set, the session ends early at the first
# matching `bridge-status:` line (used for the guest bridge setup, whose
# background systemd units can keep the ssh session console open).
guest_sh() {
    remote_cmd=$1
    sentinel="${2:-}"
    # Hard 5-minute cap on the whole session (perl alarm, not expect's own
    # timeout): expect's `timeout` only fires on silence, and a lingering
    # ssh session can trickle output forever.
    GUEST_CMD="$remote_cmd" GUEST_SENTINEL="$sentinel" perl -e 'alarm 300; exec @ARGV' expect -c '
        set timeout 240
        set done 0
        set cmd $env(GUEST_CMD)
        set sentinel $env(GUEST_SENTINEL)
        spawn ssh -p '"$guest_port"' -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=10 -o PreferredAuthentications=password \
            '"$guest_user"'@'"$guest_ip"' $cmd
        # Note: no comments inside the expect block — its body is parsed as
        # a pattern/action list, so comment lines would shift the pairing
        # and disable the timeout/eof specials. The bridge-status pattern
        # ends the session at the last line of the setup script instead of
        # waiting for sshd to close it (background relays may hold the
        # console open), and sudo prompts inside the session are answered
        # with the same password send. The session has no remote pty, so
        # sudo runs with -S and reads the password from stdin; its prompt
        # is "[sudo] password for ...: ", hence the [^:]* before the colon.
        expect {
            -re {[Pp]assword[^:]*:} { send -- "'"$guest_password"'\r"; exp_continue }
            -re {[Yy]es/[Nn]o} { send -- "yes\r"; exp_continue }
            -re {bridge-status:[^\r\n]*} { set done 1 }
            timeout { set done 1 }
            eof { }
        }
        if {$done} {
            catch { exec kill [exp_pid] }
            catch wait result
            exit 0
        }
        catch wait result
        exit [lindex $result 3]
    '
}

# --- step 5: host bridges ---------------------------------------------------

# Prints the path of the host's SSH agent socket when it is overridden, or
# nothing when the stock macOS agent (or no agent at all) is in use. Same
# logic as the other runners.
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

# Prints the path of a Docker engine socket on the host, or nothing. Same
# engines as the other runners: Docker Desktop (4.30+), Colima, OrbStack,
# and the legacy /var/run path.
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

# The host's address on Fusion's NAT network, as seen from the guest.
# Fusion's NAT is userspace (vmnetd): the guest's gateway is x.y.z.2 and
# the host's own interface on that segment is x.y.z.1 (a dynamically named
# bridgeNNN — no vmnet8). Find the host interface on the guest's subnet;
# the guest reaches the host directly at that IP.
find_host_alias() {
    local host_ip
    host_ip=$(ifconfig 2>/dev/null | awk -v gip="$guest_ip" '
        /inet / {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
                    split($i, a, "."); split(gip, b, ".")
                    if (a[1] == b[1] && a[2] == b[2] && a[3] == b[3]) { print $i }
                }
            }
        }' | grep -vx "$guest_ip" | head -n1) || true
    if [ -z "$host_ip" ]; then
        host_ip="${guest_ip%.*}.1"
    fi
    if [ -n "$host_ip" ] && [ "$host_ip" != "0.0.0.0" ]; then
        printf '%s\n' "$host_ip"
        return 0
    fi
    return 1
}

# Host-side listener: socat turns the local socket into a TCP port on the
# host's NAT-segment address (the guest's subnet host IP — the guest
# reaches the host directly there; the gateway x.y.z.2 is vmnetd and does
# not forward to the host's loopback). The listener is only reachable on
# the NAT segment, not the LAN.
start_host_bridge() {
    port="$1"
    sock="$2"

    # This function runs inside a command substitution
    # (bridge_pid=$(start_host_bridge ...)), so everything informational
    # goes to stderr and ONLY the pid goes to stdout. Messages on stdout
    # would end up in the captured pid, and — worse — a background socat
    # inheriting the substitution's stdout pipe would keep it open
    # forever: the substitution would never see EOF and the runner would
    # block.
    if ! command -v socat >/dev/null 2>&1; then
        warn "socat is not installed on the host — needed for the bridge." >&2
        if confirm "Install it with 'brew install socat' now?" y; then
            brew install socat || return 1
        else
            return 1
        fi
    fi

    if [ -z "$host_alias" ]; then
        warn "host alias is not set — was find_host_alias run?" >&2
        return 1
    fi

    if lsof -nP -iTCP@"$host_alias":"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        ok "A listener is already bound to TCP $host_alias:$port — assuming the bridge is up." >&2
        return 0
    fi

    cmd "socat TCP-LISTEN:$port,reuseaddr,fork,bind=$host_alias -> $sock" >&2
    socat TCP-LISTEN:"$port",reuseaddr,fork,bind="$host_alias" UNIX-CONNECT:"$sock" >/dev/null 2>&1 &
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
    fi
    warn "host bridge exited immediately — check the socket path." >&2
    return 1
}

# Guest-side bridge setup. The logic lives as an editable template file in
# scripts/lib/ubuntu-vmware/ (not heredocs in this script): guest-setup.sh
# renders the run's host alias + bridge ports into systemd user services
# (socat TCP <-> Unix socket relays — no extra guest binaries needed) and
# the /etc/profile.d exports, then reports a machine-readable status line
# (bridge-status:installed;<docker-ok:VERSION|docker-fail>). The services
# persist across reboots via systemd user units (linger enabled in the
# image), like the Windows sandbox's ONLOGON task.

# Returns 0 when the guest-side bridges are already set up (unit files
# present).
guest_bridge_installed() {
    guest_sh \
        "test -f \$HOME/.config/systemd/user/agent-sandbox-ssh-agent.service && echo installed || echo missing" \
        2>/dev/null | grep -q installed
}

# Renders the guest bridge setup for the current run and uploads it.
send_guest_bridge_setup() {
    local setup_b64
    setup_b64=$(
        sed -e "s/__HOST_ALIAS__/$host_alias/g" \
            -e "s/__AGENT_PORT__/$agent_port/g" \
            -e "s/__DOCKER_PORT__/$docker_port/g" \
            "$library_dir/guest-setup.sh" | base64 | tr -d '\n'
    )
    guest_sh "echo $setup_b64 | base64 -d > /tmp/agent-sandbox-guest-setup.sh && chmod +x /tmp/agent-sandbox-guest-setup.sh" ||
        return 1
}

setup_sshd_agent_bridge() {
    local sock
    if ! sock=$(find_host_agent_socket); then
        sock=
    fi
    if [ -z "$sock" ]; then
        info "No SSH agent override detected — using the default macOS agent."
        return 0
    fi

    ok "Host SSH agent socket found: $sock"
    info "Bridging it into the guest on TCP port $agent_port (see docs/ssh-agent.md)."

    if ! host_alias=$(find_host_alias); then
        warn "could not determine the host's NAT-segment address — is the VM's network up? Skipping the SSH agent bridge."
        host_alias=
        return 0
    fi
    ok "Guest reaches the host at $host_alias"

    if ! bridge_pid=$(start_host_bridge "$agent_port" "$sock"); then
        warn "skipping the SSH agent bridge."
        return 0
    fi
    agent_bridged=1
}

setup_docker_bridge() {
    local sock
    if ! sock=$(find_host_docker_socket); then
        sock=
    fi
    if [ -z "$sock" ]; then
        info "No Docker engine socket found on the host (Docker Desktop, Colima, OrbStack)."
        return 0
    fi

    ok "Host Docker engine socket found: $sock"
    info "Bridging it into the guest on TCP port $docker_port."

    if ! host_alias=$(find_host_alias); then
        warn "could not determine the host's NAT-segment address — is the VM's network up? Skipping the Docker bridge."
        host_alias=
        return 0
    fi
    ok "Guest reaches the host at $host_alias"

    if ! docker_bridge_pid=$(start_host_bridge "$docker_port" "$sock"); then
        warn "skipping the Docker bridge."
        return 0
    fi
    docker_bridged=1
}

setup_guest_bridges() {
    if guest_bridge_installed; then
        info "Guest bridges are already set up (systemd user services 'agent-sandbox-*')."
    elif confirm "Set up the bridges inside the guest too (socat relays + docker context 'host')?" y; then
        :
    else
        info "Guest bridges not configured — the socat relays and the docker context must be set up manually (see docs/ubuntu-vmware.md)."
        return 0
    fi

    # Write the rendered guest setup into the guest (idempotent), then run
    # it. Retry: right after boot sshd can answer BatchMode probes while
    # the user manager is still settling — password-auth sessions may fail
    # for a minute.
    status=
    attempt=0
    while [ "$attempt" -lt 3 ] && [ -z "$status" ]; do
        if [ "$attempt" -gt 0 ]; then
            warn "Guest bridge setup returned no status — retrying in 20 s (attempt $((attempt + 1))/3)."
            sleep 20
        fi
        if [ "$attempt" -eq 0 ]; then
            send_guest_bridge_setup || true
        fi
        status=$(guest_sh "bash /tmp/agent-sandbox-guest-setup.sh" 2>/dev/null |
            grep 'bridge-status:' | tail -n1 | tr -d '\r') || true
        attempt=$((attempt + 1))
    done

    case "$status" in
        *'docker-ok:'*)
            docker_bridge_up=1
            docker_engine_up=1
            docker_server_version=${status##*docker-ok:}
            ok "Guest bridges are up; Docker engine reachable from the guest (server version $docker_server_version)."
            ;;
        *docker-fail*)
            docker_bridge_up=1
            warn "Guest bridges are up, but the Docker engine is not reachable from the guest yet — is it running on the host?"
            ;;
        *)
            warn "Could not set up the guest bridges (is socat in the guest? Is SSH up?)."
            ;;
    esac

    # The agent socket is up iff the guest-side script ran; a status line
    # with docker-* implies the relays started for both sockets too.
    if [ -n "$status" ]; then
        guest_bridge_up=1
    fi
}

# --- step 6: shared host directory (best-effort, HGFS) -----------------------

# Shares a host directory into the guest at /mnt/hgfs/work (open-vm-tools'
# vmhgfs-fuse). Failures warn only — the sandbox works without it (git,
# OpenChamber UI, RDP clipboard).
setup_shared_folder() {
    if [ -z "$work_dir" ]; then
        return 0
    fi

    if ! vmrun list 2>/dev/null | grep -q "$work_vmx"; then
        warn "shared folder skipped — the VM is not running."
        return 0
    fi

    info "Sharing $work_dir into the guest as 'work' (/mnt/hgfs/work)."
    if ! vmrun addSharedFolder "$work_vmx" work "$work_dir" 2>/dev/null; then
        warn "addSharedFolder failed — is the share already registered? Continuing."
    fi
    vmrun enableSharedFolders "$work_vmx" runtime 2>/dev/null || true
    # Mount the share inside the guest (the mount needs root — expect
    # answers the sudo -S password prompt on the pty-less session's stdin).
    if ! guest_sh "mkdir -p /mnt/hgfs/work && sudo -S vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other,default_permissions,uid=\$(id -u),gid=\$(id -g)" >/dev/null 2>&1; then
        warn "could not mount the shared folder in the guest — is vmhgfs-fuse available (open-vm-tools)?"
        warn "try manually: sudo vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other"
    else
        ok "Shared folder mounted at /mnt/hgfs/work."
    fi
}

# --- step 6 (cont.): agent rules ---------------------------------------------
#
# Installs the sandbox environment rules into the guest's coding agents:
# opencode's global rules (~/.config/opencode/AGENTS.md) and the Copilot
# CLI's personal instructions (~/.copilot/copilot-instructions.md). The
# content ships in the repo (scripts/agent-rules-linux.md) and explains the
# runtime topology this script establishes — the Docker remote-engine
# bridge, the shared-directory path mapping, and the SSH agent bridge — so
# agents stop guessing at localhost ports and guest paths. The {{...}}
# placeholders are substituted from the actual run settings, and the SSH
# agent section is dropped unless the agent bridge is actually up — the
# rules never claim a bridge that is not running.
#
# The rules are refreshed on every run, but never written without asking:
# the probe below only inspects the guest and reports what would change
# (install / update / conflict / uptodate), and the host confirms before
# any write. A checksum marker in ~/.config/agent-sandbox/ tracks what the
# runner installed, so files the user modified are only replaced after a
# separate confirmation that defaults to no. Idempotent.

install_agent_rules() {
    agent_rules_src="$repo_root/scripts/agent-rules-linux.md"
    if [ ! -f "$agent_rules_src" ]; then
        warn "agent rules file not found: $agent_rules_src"
        return 0
    fi

    # Guest-side probe (base64-encoded so the ssh exec-request command
    # line stays quote-free): compares each target against the staged
    # /tmp/agent-rules.md and the marker. Reports the most significant
    # pending action: conflict (user-modified file) > install (missing
    # file) > update (file we installed, content changed) > uptodate.
    rules_probe=$(cat <<'GUEST_RULES_PROBE'
md=/tmp/agent-rules.md
marker="$HOME/.config/agent-sandbox/agent-rules.sha256"
prev=$(cat "$marker" 2>/dev/null || true)
new_sha=$(sha256sum "$md" | cut -d' ' -f1)
conflict=0
install=0
update=0
for target in \
    "$HOME/.config/opencode/AGENTS.md" \
    "$HOME/.copilot/copilot-instructions.md"; do
    if [ ! -f "$target" ]; then
        install=1
    elif [ "$(sha256sum "$target" | cut -d' ' -f1)" = "$new_sha" ]; then
        :
    elif [ -n "$prev" ] && \
        [ "$(sha256sum "$target" | cut -d' ' -f1)" = "$prev" ]; then
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
md=/tmp/agent-rules.md
for target in \
    "$HOME/.config/opencode/AGENTS.md" \
    "$HOME/.copilot/copilot-instructions.md"; do
    mkdir -p "$(dirname "$target")"
    cp "$md" "$target" || exit 1
done
mkdir -p "$HOME/.config/agent-sandbox"
sha256sum "$md" | cut -d' ' -f1 \
    > "$HOME/.config/agent-sandbox/agent-rules.sha256"
printf "%s\n" overwritten
GUEST_RULES_FORCE
)

    local nat_gateway="${host_alias:-${guest_ip%.*}.1}"
    local guest_mount="/mnt/hgfs/work"
    content=$(sed -e "s|{{HOST_WORK_DIR}}|${work_dir:-<not shared>}|g" \
        -e "s|{{GUEST_MOUNT}}|$guest_mount|g" \
        -e "s|{{NAT_GATEWAY}}|$nat_gateway|g" "$agent_rules_src" |
        {
            if [ "$agent_bridged" = 1 ] && [ "$guest_bridge_up" = 1 ]; then
                cat
            else
                sed '/^## SSH agent bridge$/,$d'
            fi
        }) || {
        warn "could not render the agent rules."
        return 1
    }

    # Stage the rendered rules in the guest, then probe.
    if ! printf '%s\n' "$content" | guest_sh "cat > /tmp/agent-rules.md"; then
        warn "could not stage the agent rules in the guest."
        return 1
    fi

    probe_b64=$(printf '%s\n' "$rules_probe" | base64 | tr -d '\n')
    rules_state=
    if ! rules_state=$(guest_sh "echo $probe_b64 | base64 -d | bash" 2>/dev/null | tail -n1 | tr -d '\r'); then
        rules_state=failed
        warn "could not inspect the agent rules in the guest."
        return 1
    fi

    case "$rules_state" in
        install | update)
            if confirm "Install/update the sandbox agent rules in the guest?" y; then
                force_b64=$(printf '%s\n' "$rules_force" | base64 | tr -d '\n')
                if guest_sh "echo $force_b64 | base64 -d | bash" >/dev/null 2>&1; then
                    if [ "$rules_state" = install ]; then
                        rules_state=installed
                    else
                        rules_state=updated
                    fi
                    info "Agent rules $([ "$rules_state" = installed ] && echo installed || echo updated) in the guest (opencode AGENTS.md + Copilot instructions)."
                else
                    rules_state=failed
                    warn "could not write the agent rules into the guest."
                    return 1
                fi
            else
                rules_state=skipped
                info "Skipped — the sandbox agent rules are not installed."
            fi
            ;;
        conflict)
            if confirm "The sandbox agent rules conflict with your edits in the guest — replace them?" n; then
                force_b64=$(printf '%s\n' "$rules_force" | base64 | tr -d '\n')
                if guest_sh "echo $force_b64 | base64 -d | bash" >/dev/null 2>&1; then
                    rules_state=updated
                    info "Agent rules replaced in the guest (opencode AGENTS.md + Copilot instructions)."
                else
                    rules_state=failed
                    warn "could not write the agent rules into the guest."
                    return 1
                fi
            else
                rules_state=skipped
                info "Skipped — your edited copies are kept."
            fi
            ;;
        uptodate)
            info "Sandbox agent rules are up to date in the guest."
            ;;
        *)
            warn "unexpected agent-rules probe result: '$rules_state'."
            ;;
    esac
}

# --- step 7: user settings --------------------------------------------------
#
# Copies the host's user settings into the guest: opencode config + auth,
# OpenCodeReview config, Copilot config + skills, VS Code extensions + user
# config, mcp-compress-router settings, ~/.ssh and ~/.gitconfig. The logic
# lives in scripts/lib/ubuntu-vmware/settings.sh (shared with
# scripts/sync-ubuntu-vmware-sandbox.sh — the mirror of the macOS sandbox's
# scripts/lib/macos-settings.sh). Runs once per VM: a versioned marker in
# the guest (~/.config/agent-sandbox/settings-copied) records which settings
# version was copied, and bumping $settings_version in the lib re-runs the
# step when new settings are added.

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
        settings_state=declined
        info "Skipped — re-run the runner to copy them later."
        return 0
    fi

    if ! printf '%s\n' "$settings_list" | copy_settings_to_guest; then
        settings_state=failed
        warn "settings sync failed — see the warnings above."
        return 1
    fi

    count=$(printf '%s\n' "$settings_list" | wc -l | tr -d ' ')
    settings_state=copied
    ok "Copied $count item(s) into the guest (version $settings_version)."

    # OpenChamber runs the opencode CLI under the hood, so it holds the
    # settings it started with — restart it so the fresh copy takes effect
    # without rebooting the guest.
    restart_openchamber || true
}

# --- step 8: OpenChamber ----------------------------------------------------

verify_openchamber() {
    n=0
    printf '%s' "    Waiting for OpenChamber on http://$guest_ip:$openchamber_port (up to 7 min)"
    while [ "$n" -lt 90 ]; do
        # perl alarm wrapper: macOS curl has been observed to hang past
        # --max-time on VM ports the guest accepts but never answers —
        # alarm(4) kills it no matter what.
        code=$(perl -e 'alarm 4; exec @ARGV' curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 2 --max-time 3 \
            "http://$guest_ip:$openchamber_port" 2>/dev/null) || true
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            printf ' %s\n' "${c_green}done${c_reset}"
            openchamber_up=1
            ok "OpenChamber is up: http://$guest_ip:$openchamber_port (default password: sandbox)"
            if confirm "Open it in your browser now?" y; then
                open "http://$guest_ip:$openchamber_port" 2>/dev/null ||
                    warn "could not open a browser — open http://$guest_ip:$openchamber_port manually."
            fi
            return 0
        fi
        n=$((n + 1))
        printf '.'
        sleep 2
    done
    printf ' %s\n' "${c_yellow}failed${c_reset}"
    warn "OpenChamber did not respond on http://$guest_ip:$openchamber_port within 7 min."
    warn "check it from inside the guest (SSH): systemctl --user status agent-sandbox-openchamber"
    return 1
}

# --- summary ----------------------------------------------------------------

print_summary() {
    step "Sandbox is ready"
    printf '    %-14s %s\n' 'Image:' "$image_archive"
    printf '    %-14s %s\n' 'VM:' "$work_vmx"
    printf '    %-14s %s\n' 'Guest IP:' "$guest_ip (Fusion NAT, vmnet8)"
    printf '    %-14s %s\n' 'SSH:' "ssh $guest_user@$guest_ip (password: $guest_password)"
    if [ -n "$work_dir" ]; then
        printf '    %-14s %s\n' 'Shared:' "/mnt/hgfs/work -> $work_dir"
    fi
    if [ "$agent_bridged" = 1 ]; then
        if [ "$guest_bridge_up" = 1 ]; then
            printf '    %-14s %s\n' 'SSH agent:' "${c_green}host agent -> TCP $agent_port -> guest /tmp/ssh-agent.sock${c_reset}"
        else
            printf '    %-14s %s\n' 'SSH agent:' "${c_yellow}host bridge up (TCP $agent_port), guest relay not running${c_reset}"
        fi
    else
        printf '    %-14s %s\n' 'SSH agent:' 'not bridged'
    fi
    if [ "$docker_bridged" = 1 ]; then
        if [ "$docker_engine_up" = 1 ]; then
            printf '    %-14s %s\n' 'Docker:' "${c_green}host engine (v$docker_server_version) -> TCP $docker_port -> guest /tmp/docker.sock${c_reset}"
        elif [ "$docker_bridge_up" = 1 ]; then
            printf '    %-14s %s\n' 'Docker:' "${c_yellow}bridge up, engine not reachable in the guest — is Docker running on the host?${c_reset}"
        else
            printf '    %-14s %s\n' 'Docker:' "${c_yellow}host bridge up (TCP $docker_port), guest relay not running${c_reset}"
        fi
    else
        printf '    %-14s %s\n' 'Docker:' 'not bridged'
    fi
    case "$settings_state" in
        copied)
            printf '    %-14s %s\n' 'Settings:' "${c_green}host user settings copied into the guest (version $settings_version)${c_reset}"
            ;;
        uptodate)
            printf '    %-14s %s\n' 'Settings:' "already in the guest (version $settings_version)"
            ;;
        skipped)
            printf '    %-14s %s\n' 'Settings:' 'not copied (--no-settings)'
            ;;
        declined)
            printf '    %-14s %s\n' 'Settings:' 'not copied (declined)'
            ;;
        none)
            printf '    %-14s %s\n' 'Settings:' 'no host settings found'
            ;;
        *)
            printf '    %-14s %s\n' 'Settings:' "${c_yellow}not copied — re-run with ./scripts/sync-ubuntu-vmware-sandbox.sh${c_reset}"
            ;;
    esac
    if [ "$openchamber_up" = 1 ]; then
        printf '    %-14s %s\n' 'OpenChamber:' "${c_green}http://$guest_ip:$openchamber_port (password: sandbox)${c_reset}"
    else
        printf '    %-14s %s\n' 'OpenChamber:' "${c_yellow}not responding on http://$guest_ip:$openchamber_port${c_reset}"
    fi
    printf '    %-14s %s\n' 'State:' "$host_state_dir (extracted base + working clone; --reset re-clones)"
    printf '    %-14s %s\n' 'Stop:' "./scripts/stop-ubuntu-vmware-sandbox.sh (or: vmrun -T fusion stop '$work_vmx')"
    if [ "$agent_bridged" = 1 ]; then
        printf '    %-14s %s\n' 'Bridge:' "host socat on TCP $agent_port stays up — stop it with: ./scripts/stop-ubuntu-vmware-sandbox.sh"
    fi
    if [ "$docker_bridged" = 1 ]; then
        printf '    %-14s %s\n' 'Bridge:' "host socat on TCP $docker_port stays up — stop it with: ./scripts/stop-ubuntu-vmware-sandbox.sh"
    fi
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: run-ubuntu-vmware-sandbox.sh [options]

Runs the Ubuntu 24.04 (ARM64) sandbox VM under VMware Fusion (vmrun) and
wires up the SSH agent and Docker bridges.

By default the VM keeps running after the script exits and prints a
summary. There is no separate log: the guest console is the Fusion window
(--headless shows it in a Fusion tab instead of a separate window).

Options:
  --headless     Run without a window
  --foreground   Keep the terminal attached and block until the VM stops
                 (Cmd+C in the terminal stops the VM)
  --no-agent     Skip the SSH agent bridge setup
  --no-docker    Skip the Docker engine bridge setup
  --no-settings  Skip copying the host's user settings into the guest
  --work-dir P   Share the host directory P into the guest as
                 /mnt/hgfs/work (VMware Tools HGFS)
  --reset        Delete the working VM state (extracted base + clone) and
                 start fresh from the pristine image
  -h, --help     Show this help

Environment:
  UBUNTU_VMWARE_IMAGE      path to a local sandbox-ubuntu-24-04-arm64-vmware.tar.gz
  SANDBOX_STATE_DIR        working VM state dir
  UBUNTU_PASSWORD          admin password in the guest
  SANDBOX_OPENCHAMBER_PORT guest port of OpenChamber (4000)
  SANDBOX_AGENT_PORT       TCP port for the SSH agent bridge (4400)
  SANDBOX_DOCKER_PORT      TCP port for the Docker engine bridge (4401)
  GHCR_OWNER               GHCR owner for pulls (git remote)
  NO_COLOR                 disable colored output
EOF
}

for arg in "$@"; do
    case "$arg" in
        --headless) headless=1 ;;
        --foreground) detached=0 ;;
        --no-agent) skip_agent=1 ;;
        --no-docker) skip_docker=1 ;;
        --no-settings) skip_settings=1 ;;
        --work-dir)
            shift
            [ $# -ge 1 ] || { echo "missing argument for --work-dir" >&2; usage >&2; exit 1; }
            work_dir=$1
            ;;
        --reset) reset_vm=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

# Foreground mode: tear down what this run started when the script exits
# (Cmd+C stops the VM via vmrun; the host bridges must be stopped
# explicitly). Background mode leaves everything up — the VM and its
# bridges outlive this script by design.
cleanup() {
    if [ "$detached" = 0 ] && [ -n "$work_vmx" ]; then
        if [ -n "$docker_bridge_pid" ]; then
            kill "$docker_bridge_pid" 2>/dev/null || true
            info "Stopped the host Docker bridge (pid $docker_bridge_pid)."
        fi
        if [ -n "$bridge_pid" ]; then
            kill "$bridge_pid" 2>/dev/null || true
            info "Stopped the host socat bridge (pid $bridge_pid)."
        fi
        if vmrun list 2>/dev/null | grep -q "$work_vmx"; then
            info "Stopping the sandbox VM..."
            vmrun stop "$work_vmx" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

title "Ubuntu VMware sandbox: $image_name"

# 0. Prerequisites.
ensure_prereqs

# Credentials come from the image's vars file (single source of truth;
# UBUNTU_PASSWORD overrides after changing it in the guest).
[ -f "$vars_file" ] || die "vars file not found: $vars_file"
guest_user=$(read_var ssh_username)
[ -n "$guest_user" ] || guest_user=admin
guest_password=${UBUNTU_PASSWORD:-$(read_var ssh_password)}
[ -n "$guest_password" ] || die "could not read ssh_password from $vars_file"

# Stop a VM left running by a previous run before touching the state dir
# (--reset would otherwise delete files a live VM still holds).
step "Step 0/8: Running VM check"
stop_running_vm

# 1. Pick the image (local build output, env override, or GHCR pull).
step "Step 1/8: Sandbox image"
image_archive=$(pick_image)
ok "Using archive: $image_archive"

# 2. Working VM state (extracted base + full clone).
step "Step 2/8: Working VM state"
ensure_base
if ! ensure_working_vm; then
    die "could not clone the working VM (see above). Check Fusion's VM library path and re-run."
fi
upgrade_working_vm

# 3. Boot.
step "Step 3/8: Starting the VM"
launch_vm
wait_guest_ip
ok "Guest IP: $guest_ip"
wait_for_sshd "the guest to boot" 150
ok "VM is up: ssh $guest_user@$guest_ip"

# 4. Shared host directory (best-effort).
step "Step 4/8: Shared folder"
setup_shared_folder

# Host-side bridges must be up before the guest-side setup connects to
# them. The guest side only runs when SSH answers.
if [ "$skip_agent" = 1 ]; then
    info "Skipping SSH agent bridge setup (--no-agent)."
else
    setup_sshd_agent_bridge
fi
if [ "$skip_docker" = 1 ]; then
    info "Skipping Docker bridge setup (--no-docker)."
else
    setup_docker_bridge
fi

# 5. Guest-side bridges (socat systemd relays + docker context), over SSH.
step "Step 5/8: Guest bridges"
if [ "$skip_agent" = 1 ] && [ "$skip_docker" = 1 ]; then
    info "Both bridges skipped — nothing to set up in the guest."
elif [ "$agent_bridged" = 0 ] && [ "$docker_bridged" = 0 ]; then
    info "No host bridges needed (no SSH agent override, no Docker engine) — nothing to set up in the guest."
else
    setup_guest_bridges
fi

# 6. Sandbox agent rules (opencode AGENTS.md + Copilot instructions).
step "Step 6/8: Agent rules"
install_agent_rules

# 7. Host user settings (opencode config + auth, Copilot config + skills,
# VS Code extensions + user config, ~/.ssh, ~/.gitconfig) — once per VM.
step "Step 7/8: User settings"
if [ "$skip_settings" = 1 ]; then
    info "Skipping user settings copy (--no-settings)."
    settings_state=skipped
else
    setup_user_settings
fi

# 8. Verify OpenChamber and offer to open it.
step "Step 8/8: OpenChamber"
verify_openchamber || true

print_summary

# Foreground mode: keep the terminal attached until the VM stops. Cmd+C
# triggers the EXIT trap (vmrun stop + bridge teardown). In background
# mode everything stays up — the VM and its bridges outlive this script
# by design.
if [ "$detached" = 0 ] && [ -n "$work_vmx" ]; then
    info "Waiting for the VM to stop (Cmd+C to stop it now)..."
    while vmrun list 2>/dev/null | grep -q "$work_vmx"; do
        sleep 3
    done
    info "VM stopped."
fi
