#!/bin/bash
#
# run-windows-vmware-sandbox.sh — run and wire up a Windows 11 (ARM64)
# sandbox VM under VMware Fusion.
#
# Usage:
#   ./scripts/run-windows-vmware-sandbox.sh [--headless] [--foreground]
#                                            [--no-agent] [--no-docker]
#                                            [--work-dir PATH] [--reset]
#
# The Windows VMware sandbox is a .vmx + .vmdk VM (built by
# images/windows-arm64-vmware/, published to GHCR as a tar.gz), not a Tart
# VM — so unlike run-macos-sandbox.sh this script drives vmrun directly.
# What it does:
#
#   1. Picks the VM archive: $WINDOWS_VMWARE_IMAGE if set, else the local
#      build output (build/windows-arm64-vmware/output/
#      sandbox-windows-11-arm64-vmware.tar.gz, created on demand), else pulls
#      sandbox-windows-11-arm64-vmware:latest from GHCR via oras (asks first).
#      The pristine VM is never written to: the archive is extracted into
#      ~/Library/Application Support/agent-sandbox/windows-11-arm64-vmware/ and
#      a full clone becomes the working VM, so the working VM survives
#      reboots of the guest and reruns of this script. --reset deletes the
#      working state and starts from the pristine clone. The clone is
#      upgraded in place to the hardware version the installed Fusion
#      supports (vmrun upgradevm, shared helper in scripts/lib/windows-vmware/
#      — the image builds at hardware version 20 and a newer Fusion would
#      prompt once on the first GUI start); recorded in .hw-version so it
#      runs once per clone.
#   2. Boots the working VM with vmrun (headless or in a Fusion window).
#      No port forwarding: the VM sits on Fusion's NAT network (vmnet8)
#      and the host is that network's router, so SSH (22), RDP (3389),
#      OpenChamber (4000) and WinRM (5985) are reachable directly at the
#      guest IP that vmrun getGuestIPAddress reports (the image installs
#      VMware Tools for exactly this). The guest auto-logs in
#      (AutoAdminLogon) and the OpenChamber scheduled task fires at logon,
#      so the web UI comes up without interaction. By default the VM keeps
#      running after the script exits (log summary at the end);
#      --foreground also blocks until the VM stops.
#   3. Bridges the host's SSH agent into the guest when SSH_AUTH_SOCK is
#      overridden by a password manager (see docs/ssh-agent.md): a host-side
#      socat turns the agent socket into TCP port 4300 on the host's
#      vmnet8 address (reachable from the guest at that IP), and a
#      guest-side Node relay (C:\tools\bridge-relay.js, rendered by the
#      runner from scripts/lib/windows-vmware/bridge-relay.js and served
#      by the image's node.exe) presents it as the
#      \\.\pipe\openssh-ssh-agent named pipe (Windows OpenSSH's
#      SSH_AUTH_SOCK). The guest side is persisted as an ONLOGON
#      scheduled task and auto-starts; the host side only lives for this
#      run.
#   4. Bridges the host's Docker engine the same way when one is running
#      (Docker Desktop, Colima, OrbStack, ...): host socat on TCP 4301,
#      guest Node relay serving \\.\pipe\docker_engine, docker context
#      'host' created and made the default, so `docker` and `docker
#      compose` in the guest hit the host engine. --no-docker skips.
#   5. Optionally shares a host directory into the guest (SANDBOX_WORK_DIR
#      or --work-dir PATH, HGFS via VMware Tools; visible as
#      \\vmware-host\Shared Folders\work in the guest).
#   6. Verifies that OpenChamber answers on http://<guest-ip>:4000 and
#      offers to open it in the browser.
#
# Not wired up (yet): the sandbox agent rules (scripts/agent-rules.md)
# are macOS-flavored and not installed into Windows guests.
#
# Environment (defaults in parentheses):
#   WINDOWS_VMWARE_IMAGE   path to a local sandbox-windows-11-arm64-vmware.tar.gz
#                          to run instead of the discovered/pulled one
#   SANDBOX_STATE_DIR      working VM state dir
#                          (~/Library/Application Support/agent-sandbox/windows-11-arm64-vmware)
#   WINDOWS_PASSWORD       Administrator password in the guest (read
#                          from the image's vars file; override after
#                          changing it in the guest)
#   SANDBOX_OPENCHAMBER_PORT guest port of OpenChamber (4000)
#   SANDBOX_AGENT_PORT     TCP port for the SSH agent bridge (4300)
#   SANDBOX_DOCKER_PORT    TCP port for the Docker engine bridge (4301)
#   SANDBOX_WORK_DIR       host dir to share into the guest; --work-dir
#                          overrides it. Empty disables the share.
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

image_name=sandbox-windows-11-arm64-vmware
platform_dir="$repo_root/images/windows-arm64-vmware"
vars_file="$platform_dir/vars/${image_name}.pkrvars.hcl"
host_state_dir="${SANDBOX_STATE_DIR:-$HOME/Library/Application Support/agent-sandbox/windows-11-arm64-vmware}"
# The working clone's display name in Fusion's VM library. `vmrun clone`
# inherits the source vmx's displayName ("sandbox-windows-11-arm64-vmware"), so
# without a rename the working VM would be indistinguishable from the
# pristine base (both would show under the base's name).
vm_display_name="agent-sandbox-windows-11-arm64-vmware"
agent_port=${SANDBOX_AGENT_PORT:-4300}
docker_port=${SANDBOX_DOCKER_PORT:-4301}
openchamber_port=${SANDBOX_OPENCHAMBER_PORT:-4000}
guest_port=22

headless=0
detached=1
skip_agent=0
skip_docker=0
reset_vm=0
# The shared host directory: SANDBOX_WORK_DIR (empty = no share), the
# --work-dir flag overrides it.
work_dir=${SANDBOX_WORK_DIR:-}

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

# Deterministic state-dir paths (stop_running_vm needs them before any
# state is created).
base_dir="$host_state_dir/base"
base_marker="$host_state_dir/base-archive.txt"
base_vmx="$base_dir/${image_name}.vmx"
work_vmx="$host_state_dir/working/${image_name}.vmx"

# --- shared library ---------------------------------------------------------
#
# scripts/lib/windows-vmware/lib.sh: vmrun resolution (PATH > Fusion app
# bundle) and the VM hardware-version upgrade (post-build + working-clone
# step; see upgrade_working_vm below).

library_dir="$repo_root/scripts/lib/windows-vmware"
# shellcheck source=scripts/lib/windows-vmware/lib.sh
source "$library_dir/lib.sh"

# --- output helpers (same conventions as the macOS runner) ------------------

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

# Per-image build directory, mirroring images/windows-arm64-vmware/build.sh:
# the local build output fallback lives in build/windows-arm64-vmware/.
build_dir="$repo_root/build/windows-arm64-vmware"

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
    if [ -n "${WINDOWS_VMWARE_IMAGE:-}" ]; then
        [ -f "$WINDOWS_VMWARE_IMAGE" ] || die "WINDOWS_VMWARE_IMAGE points to a file that does not exist: $WINDOWS_VMWARE_IMAGE"
        printf '%s\n' "$WINDOWS_VMWARE_IMAGE"
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
        die "oras is not installed — needed to pull $registry:latest (brew install oras). Set WINDOWS_VMWARE_IMAGE to a local archive to skip."
    if confirm "Pull $registry:latest (one-time, ~20 GB download)?" y; then
        mkdir -p "$host_state_dir/image"
        (cd "$host_state_dir/image" && oras pull "$registry:latest") ||
            die "oras pull failed — check your network connection (public GHCR images pull without a login)."
        [ -f "$cached" ] || die "oras pull produced no $cached — is the image published under $registry?"
        printf '%s\n' "$cached"
    else
        die "aborted — no sandbox image available. Set WINDOWS_VMWARE_IMAGE to a local archive or pull manually."
    fi
}

# --- step 3: working VM state (extracted base + full clone) -----------------

# Extracts the pristine archive into the state dir (once per archive) and
# clones a working VM from it. The base is never written to; the clone is
# the sandbox. When the archive changes (new build/pull), both are
# recreated.
ensure_base() {
    if [ "$reset_vm" = 1 ]; then
        info "Resetting the working VM (--reset) — deleting the extracted base and the working clone."
        rm -rf "$host_state_dir"
    fi

    if [ -f "$base_marker" ] && [ "$(cat "$base_marker")" != "$image_archive" ]; then
        warn "The archive changed (new build or pull) — re-extracting the pristine VM and dropping the working clone."
        rm -rf "$base_dir" "$host_state_dir/working"
    fi

    if [ -f "$base_marker" ] && [ "$(cat "$base_marker")" = "$image_archive" ] &&
        [ -f "$base_vmx" ]; then
        ok "Pristine VM extracted ($base_dir)."
        return 0
    fi

    mkdir -p "$base_dir"
    cmd "tar -xzf $image_archive -C $base_dir"
    tar -xzf "$image_archive" -C "$base_dir"
    printf '%s\n' "$image_archive" >"$base_marker"
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

# Waits for the guest IP (VMware Tools reports it — the image installs the
# tools). vmrun's getGuestIPAddress has no timeout, so poll with the perl
# alarm wrapper (macOS curl/vmrun have been observed to hang past their
# own timeouts; alarm(4)/alarm(30) kills them no matter what).
wait_guest_ip() {
    n=0
    printf '%s' "    Waiting for the guest IP (VMware Tools; up to 15 min)"
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
    die "timed out waiting for the guest IP — is VMware Tools running in the guest? (vmrun -T fusion list to check the VM)"
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

# The image's autounattend.xml sets LogonCount=1: exactly one auto-login
# (the OOBE boot), after which Windows clears AutoAdminLogon — so every
# later boot lands on the lock screen and the OpenChamber ONLOGON task
# never fires. Re-enable it once (the registry keys persist in the
# working VM) and reboot the guest so the task runs at the auto-logon.
ensure_autologon() {
    # grep -o: PowerShell's CLIXML progress noise rides along on stdout,
    # so a plain tail would pick XML junk instead of the answer.
    state=$(guest_ps "
        \$w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
        if (\$w.AutoAdminLogon -eq 1 -and \$w.DefaultUserName -eq '$guest_user' -and \$w.DefaultPassword) {
            'enabled'
        } else {
            'disabled'
        }
    " 2>/dev/null | grep -o 'enabled\|disabled' | tail -n1)
    case "$state" in
        *enabled*)
            ok "Guest auto-logon is enabled — OpenChamber starts at logon."
            return 0
            ;;
    esac

    info "Guest auto-logon is disabled (the image allows one OOBE logon only)."
    if ! confirm "Enable auto-logon and reboot the guest so OpenChamber starts at boot?" y; then
        info "OpenChamber will not start until someone logs in via RDP or the console."
        return 0
    fi

    guest_ps "
        \$w = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        New-Item -Path \$w -Force | Out-Null
        Set-ItemProperty -Path \$w -Name AutoAdminLogon -Value '1'
        Set-ItemProperty -Path \$w -Name DefaultUserName -Value '$guest_user'
        Set-ItemProperty -Path \$w -Name DefaultPassword -Value '$guest_password'
        shutdown /r /t 0
    " >/dev/null 2>&1 || true
    info "Rebooting the guest (a minute or two)..."
    wait_guest_ip
    # The ssh session dies with the shutdown; wait for sshd to come back.
    wait_for_sshd "the guest to reboot" 150
    ok "Guest rebooted with auto-logon enabled."
}

# --- guest shell ------------------------------------------------------------

# Runs a PowerShell snippet in the guest over SSH (expect drives the
# password prompt — macOS ships expect; sshpass does not exist). The
# snippet is base64-encoded (UTF-16LE) and passed via -EncodedCommand, so
# quoting stays sane. stdout passes through.
#
# The payload travels in an env var: expect treats extra argv as script
# FILES, so `expect -c ... "$b64"` would fail with "couldn't read file".
# And never block on `wait`: a Windows sshd session can linger after the
# command finished (background processes hold the console handles), so
# when the output patterns don't complete in time the ssh client is
# killed instead of waiting forever. The exit status is ssh's own when
# the session ended naturally (the remote exit code propagates).
guest_ps() {
    b64=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64)
    # Hard 5-minute cap on the whole session (perl alarm, not expect's
    # own timeout): expect's `timeout` only fires on silence, and a guest
    # sshd session left open by background relays can trickle output
    # forever.
    GUEST_PS_B64="$b64" perl -e 'alarm 300; exec @ARGV' expect -c '
        set timeout 240
        set done 0
        set b64 $env(GUEST_PS_B64)
        spawn ssh -p '"$guest_port"' -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=10 -o PreferredAuthentications=password \
            '"$guest_user"'@'"$guest_ip"' \
            powershell -NoProfile -NonInteractive -EncodedCommand $b64
        # Note: no comments inside the expect block — its body is parsed as
        # a pattern/action list, so comment lines would shift the pairing
        # and disable the timeout/eof specials. The bridge-status pattern
        # ends the session at the last line of the setup script instead of
        # waiting for sshd to close it (background relays may hold the
        # console open).
        expect {
            -re {[Pp]assword:} { send -- "'"$guest_password"'\r"; exp_continue }
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
# logic as the macOS runner.
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
# engines as the macOS runner: Docker Desktop (4.30+), Colima, OrbStack,
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
# the host's own interface on that segment is x.y.z.1 (a dynamically
# named bridgeNNN — no vmnet8). Find the host interface on the guest's
# subnet; the guest reaches the host directly at that IP.
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

# Guest-side bridge setup. The bridge scripts live as editable template
# files in scripts/lib/windows-vmware/ (not heredocs in this script):
#
#   - bridge-relay.js — a tiny Node relay that serves a Windows named pipe
#     and forwards every connection to a TCP endpoint. Node is in the
#     image, and net.createServer().listen('\\.\pipe\...') is a native
#     Windows named-pipe server, so no extra binaries are needed.
#     (npiperelay cannot do this: its -ep/-s flags are EOF-handling
#     options, and it only CONNECTS to existing pipes.)
#   - bridges.ps1 — the idempotent bridge logic (start the relays, set
#     SSH_AUTH_SOCK, docker context 'host'), rendered with this run's
#     bridge ports + host alias; also what the ONLOGON task runs at every
#     logon (AutoAdminLogon fires it at boot).
#   - start-relays.cmd — the detached relay bootstrap (SYSTEM ONCE task;
#     the task is the detach mechanism: relays started from an ssh session
#     die when sshd tears the session down, task-spawned ones live on).
#   - guest-setup.ps1 — the one-time installer: registers the tasks, runs
#     the logic once, and reports a machine-readable status line
#     (bridge-status:installed;<docker-ok:VERSION|docker-fail>).
#
# The runner writes the files into C:\tools with one small SSH exec per
# file (write_guest_file): a single combined payload tripled the encoded
# size and overran the Windows OpenSSH exec-request command line
# ("exec request failed on channel 0").

# Writes one base64-encoded file into the guest (only when the content
# changed). The snippet is small, so the encoded exec stays well under the
# OpenSSH command-line limit.
write_guest_file() {
    guest_ps "
        \$b = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$2'))
        \$old = if (Test-Path '$1') { Get-Content '$1' -Raw } else { '' }
        if (\$old -ne \$b) { [IO.File]::WriteAllText('$1', \$b, (New-Object System.Text.UTF8Encoding(\$false))) }
    " >/dev/null 2>&1
}

# Renders the three guest-side bridge files for the current run and writes
# them into C:\tools. base64 keeps the payload quoting-free (no quotes or
# newlines once unwrapped with tr -d '\n').
send_guest_bridge_files() {
    local relay_b64 bridges_b64 cmd_b64
    relay_b64=$(base64 <"$library_dir/bridge-relay.js" | tr -d '\n')
    bridges_b64=$(
        sed -e "s/__AGENT_PORT__/$agent_port/g" \
            -e "s/__DOCKER_PORT__/$docker_port/g" \
            -e "s/__HOST_ALIAS__/$host_alias/g" \
            "$library_dir/bridges.ps1" | base64 | tr -d '\n'
    )
    cmd_b64=$(
        sed -e "s/__AGENT_PORT__/$agent_port/g" \
            -e "s/__DOCKER_PORT__/$docker_port/g" \
            -e "s/__HOST_ALIAS__/$host_alias/g" \
            "$library_dir/start-relays.cmd" | base64 | tr -d '\n'
    )
    write_guest_file 'C:\tools\bridge-relay.js' "$relay_b64" || return 1
    write_guest_file 'C:\tools\bridges.ps1' "$bridges_b64" || return 1
    write_guest_file 'C:\tools\start-relays.cmd' "$cmd_b64" || return 1
    # The scripts (incl. the task's) must be able to load. Images since
    # the execution-policy fix bake in machine-wide RemoteSigned; this
    # runtime set is kept for images built before the fix (Restricted).
    guest_ps "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
}

# Returns 0 when the guest-side bridges are already set up (scheduled
# task registered).
guest_bridge_installed() {
    guest_ps "
        if (Get-ScheduledTask -TaskName 'agent-sandbox-bridges' -ErrorAction SilentlyContinue) { exit 0 }
        exit 1
    " >/dev/null 2>&1
}

setup_ssh_agent() {
    sock=
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
    sock=
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
        info "Guest bridges are already set up (scheduled task 'agent-sandbox-bridges')."
    elif confirm "Set up the bridges inside the guest too (Node relays + docker context 'host')?" y; then
        :
    else
        info "Guest bridges not configured — the Node relays and the docker context must be set up manually (see docs/windows-vmware.md)."
        return 0
    fi

    # Write the rendered bridge files into C:\tools (one small SSH exec
    # per file; idempotent — already-existing identical files are kept).
    if ! send_guest_bridge_files; then
        warn "Could not write the bridge scripts into the guest (is SSH up?)."
        return 0
    fi

    # Right after the auto-logon reboot the guest's sshd can answer
    # BatchMode probes while the profile service is still settling (the
    # auto-logon loads the same profile) — password-auth sessions may fail
    # for a minute. Retry the setup until it reports a status.
    status=
    attempt=0
    while [ "$attempt" -lt 3 ] && [ -z "$status" ]; do
        if [ "$attempt" -gt 0 ]; then
            warn "Guest bridge setup returned no status — retrying in 20 s (attempt $((attempt + 1))/3)."
            sleep 20
        fi
        status=$(guest_ps "$(<"$library_dir/guest-setup.ps1")" 2>/dev/null | grep 'bridge-status:' | tail -n1 | tr -d '\r') || true
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
            warn "Could not set up the guest bridges (is the Node relay in the guest? Is SSH up?)."
            ;;
    esac

    # The agent pipe is up iff the guest-side script ran; a status line
    # with docker-* implies the relays started for the pipes too.
    if [ -n "$status" ]; then
        guest_bridge_up=1
    fi
}

# --- step 6: shared host directory (best-effort, HGFS) -----------------------

# Shares a host directory into the guest at \\vmware-host\Shared Folders\
# <name> (VMware Tools HGFS). The guest sees the share
# "work" (or C:\shared if the network share mapping is set up; the raw
# UNC path always works). Failures warn only — the sandbox works without
# it (git, RDP clipboard, OpenChamber UI).
setup_shared_folder() {
    if [ -z "$work_dir" ]; then
        return 0
    fi

    if [ ! -d "$work_dir" ]; then
        warn "work directory '$work_dir' does not exist — skipping the shared-directory share."
        return 0
    fi

    if ! vmrun list 2>/dev/null | grep -q "$work_vmx"; then
        warn "shared folder skipped — the VM is not running."
        return 0
    fi

    info "Sharing $work_dir into the guest as 'work' (\\vmware-host\Shared Folders\work)."
    if ! vmrun addSharedFolder "$work_vmx" work "$work_dir" 2>/dev/null; then
        warn "addSharedFolder failed — is the share already registered? Continuing."
    fi
    vmrun enableSharedFolders "$work_vmx" runtime 2>/dev/null || true
    ok "Shared folder registered (best-effort — HGFS must be enabled by VMware Tools)."
}

# --- step 7: OpenChamber ----------------------------------------------------

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
    warn "check it from inside the guest (RDP or SSH): openchamber status / openchamber logs"
    return 1
}

# --- summary ----------------------------------------------------------------

print_summary() {
    step "Sandbox is ready"
    printf '    %-14s %s\n' 'Image:' "$image_archive"
    printf '    %-14s %s\n' 'VM:' "$work_vmx"
    printf '    %-14s %s\n' 'Guest IP:' "$guest_ip (Fusion NAT, vmnet8)"
    printf '    %-14s %s\n' 'SSH:' "ssh $guest_user@$guest_ip (password: $guest_password)"
    printf '    %-14s %s\n' 'RDP:' "$guest_ip:3389 ($guest_user / $guest_password)"
    printf '    %-14s %s\n' 'WinRM:' "$guest_ip:5985 (advanced use)"
    if [ -n "$work_dir" ]; then
        printf '    %-14s %s\n' 'Shared:' "\\\\vmware-host\\Shared Folders\\work -> $work_dir"
    else
        printf '    %-14s %s\n' 'Shared:' 'not shared'
    fi
    if [ "$agent_bridged" = 1 ]; then
        if [ "$guest_bridge_up" = 1 ]; then
            printf '    %-14s %s\n' 'SSH agent:' "${c_green}host agent -> TCP $agent_port -> guest \\.\pipe\openssh-ssh-agent${c_reset}"
        else
            printf '    %-14s %s\n' 'SSH agent:' "${c_yellow}host bridge up (TCP $agent_port), guest pipe not running${c_reset}"
        fi
    else
        printf '    %-14s %s\n' 'SSH agent:' 'not bridged'
    fi
    if [ "$docker_bridged" = 1 ]; then
        if [ "$docker_engine_up" = 1 ]; then
            printf '    %-14s %s\n' 'Docker:' "${c_green}host engine (v$docker_server_version) -> TCP $docker_port -> guest (context 'host')${c_reset}"
        elif [ "$docker_bridge_up" = 1 ]; then
            printf '    %-14s %s\n' 'Docker:' "${c_yellow}bridge up, engine not reachable in the guest — is Docker running on the host?${c_reset}"
        else
            printf '    %-14s %s\n' 'Docker:' "${c_yellow}host bridge up (TCP $docker_port), guest pipe not running${c_reset}"
        fi
    else
        printf '    %-14s %s\n' 'Docker:' 'not bridged'
    fi
    if [ "$openchamber_up" = 1 ]; then
        printf '    %-14s %s\n' 'OpenChamber:' "${c_green}http://$guest_ip:$openchamber_port (password: sandbox)${c_reset}"
    else
        printf '    %-14s %s\n' 'OpenChamber:' "${c_yellow}not responding on http://$guest_ip:$openchamber_port${c_reset}"
    fi
    printf '    %-14s %s\n' 'State:' "$host_state_dir (extracted base + working clone; --reset re-clones)"
    printf '    %-14s %s\n' 'Stop:' "./scripts/stop-windows-vmware-sandbox.sh (or: vmrun -T fusion stop '$work_vmx')"
    if [ "$agent_bridged" = 1 ]; then
        printf '    %-14s %s\n' 'Bridge:' "host socat on TCP $agent_port stays up — stop it with: ./scripts/stop-windows-vmware-sandbox.sh"
    fi
    if [ "$docker_bridged" = 1 ]; then
        printf '    %-14s %s\n' 'Bridge:' "host socat on TCP $docker_port stays up — stop it with: ./scripts/stop-windows-vmware-sandbox.sh"
    fi
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: run-windows-vmware-sandbox.sh [options]

Runs the Windows 11 (ARM64) sandbox VM under VMware Fusion (vmrun) and
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
  --work-dir P   Share the host directory P into the guest as
                 \\vmware-host\Shared Folders\work (VMware Tools HGFS);
                 overrides SANDBOX_WORK_DIR
  --reset        Delete the working VM state (extracted base + clone) and
                 start fresh from the pristine image
  -h, --help     Show this help

Environment:
  WINDOWS_VMWARE_IMAGE     path to a local sandbox-windows-11-arm64-vmware.tar.gz
  SANDBOX_STATE_DIR        working VM state dir
  WINDOWS_PASSWORD         Administrator password in the guest
  SANDBOX_OPENCHAMBER_PORT guest port of OpenChamber (4000)
  SANDBOX_AGENT_PORT       TCP port for the SSH agent bridge (4300)
  SANDBOX_DOCKER_PORT      TCP port for the Docker engine bridge (4301)
  SANDBOX_WORK_DIR         host dir to share into the guest (empty = no
                           share); --work-dir overrides it
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

title "Windows VMware sandbox: $image_name"

# 0. Prerequisites.
ensure_prereqs

# Credentials come from the image's vars file (single source of truth;
# WINDOWS_PASSWORD overrides after changing it in the guest).
[ -f "$vars_file" ] || die "vars file not found: $vars_file"
guest_user=$(read_var winrm_username)
[ -n "$guest_user" ] || guest_user=Administrator
guest_password=${WINDOWS_PASSWORD:-$(read_var winrm_password)}
[ -n "$guest_password" ] || die "could not read winrm_password from $vars_file"

# Stop a VM left running by a previous run before touching the state dir
# (--reset would otherwise delete files a live VM still holds).
step "Step 0/6: Running VM check"
stop_running_vm

# 1. Pick the image (local build output, env override, or GHCR pull).
step "Step 1/6: Sandbox image"
image_archive=$(pick_image)
ok "Using archive: $image_archive"

# 2. Working VM state (extracted base + full clone).
step "Step 2/6: Working VM state"
ensure_base
if ! ensure_working_vm; then
    die "could not clone the working VM (see above). Check Fusion's VM library path and re-run."
fi
upgrade_working_vm

# 3. Boot (+ one-time auto-logon so the OpenChamber task fires at boot).
step "Step 3/6: Starting the VM"
launch_vm
wait_guest_ip
ok "Guest IP: $guest_ip"
wait_for_sshd "the guest to boot" 150
ok "VM is up: ssh $guest_user@$guest_ip"
ensure_autologon

# 4. Shared host directory (best-effort).
step "Step 4/6: Shared folder"
setup_shared_folder

# Host-side bridges must be up before the guest-side setup connects to
# them. The guest side only runs when SSH answers.
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

# 5. Guest-side bridges (Node relay named pipes + docker context), over SSH.
step "Step 5/6: Guest bridges"
if [ "$skip_agent" = 1 ] && [ "$skip_docker" = 1 ]; then
    info "Both bridges skipped — nothing to set up in the guest."
elif [ "$agent_bridged" = 0 ] && [ "$docker_bridged" = 0 ]; then
    info "No host bridges needed (no SSH agent override, no Docker engine) — nothing to set up in the guest."
else
    setup_guest_bridges
fi

# 6. Verify OpenChamber and offer to open it.
step "Step 6/6: OpenChamber"
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
