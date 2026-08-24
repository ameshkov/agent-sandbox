#!/bin/bash
#
# run-windows-qemu-sandbox.sh — run and wire up a Windows 11 (ARM64) sandbox VM.
#
# Usage:
#   ./scripts/run-windows-qemu-sandbox.sh [--headless] [--foreground]
#                                    [--no-agent] [--no-docker] [--reset]
#
# The Windows sandbox is a qcow2 disk image (built by
# images/windows-arm64-qemu/, published to GHCR), not a Tart VM — so unlike
# run-macos-sandbox.sh this script drives qemu-system-aarch64 directly.
# What it does:
#
#   1. Picks the disk image: $WINDOWS_IMAGE if set, else the local build
#      output (build/windows-arm64-qemu/output/sandbox-windows-11-arm64-qemu.qcow2),
#      else pulls sandbox-windows-11-arm64-qemu:latest from GHCR via oras (asks
#      first). The pristine image is never written to: a qcow2 copy-on-write
#      overlay plus a persistent TPM state and EFI NVRAM store live in
#      ~/Library/Application Support/agent-sandbox/windows-11-arm64-qemu/, so the
#      working VM survives reboots of the guest and reruns of this script.
#      --reset deletes the working state and starts from the pristine image.
#   2. Starts swtpm (TPM 2.0 — Windows 11 requires it, and the image's
#      TPM state must persist for the credentials inside the guest to keep
#      working) and boots the overlay with the same wiring the image was
#      built with (see images/windows-arm64-qemu/qemu-with-tpm.sh): ARM
#      virt machine, HVF accelerator, AAVMF UEFI, virtio-gpu-pci display,
#      xhci + keyboard + tablet. Guest ports are forwarded to the host:
#      SSH 2222, RDP 3389, OpenChamber 4000, WinRM 5985. The guest
#      auto-logs in (AutoAdminLogon) and the OpenChamber scheduled task
#      fires at logon, so the web UI comes up without interaction. By
#      default qemu runs in the background (log:
#      ~/Library/Logs/agent-sandbox/qemu-windows-11.log); --foreground
#      keeps the terminal attached instead. The Cocoa window is resizable
#      by default (-display cocoa,zoom-to-fit=on): drag it and the guest
#      scales to fit while keeping its aspect ratio; the window's View
#      menu offers native full screen and toggling Zoom To Fit.
#   3. Bridges the host's SSH agent into the guest when SSH_AUTH_SOCK is
#      overridden by a password manager (see docs/ssh-agent.md): a host-side
#      socat turns the agent socket into TCP port 4200 on the host
#      loopback (reachable from the guest at 10.0.2.2), and a guest-side
#      Node relay (C:\tools\bridge-relay.js, written by the runner and
#      served by the image's node.exe) presents it as the
#      \\.\pipe\openssh-ssh-agent named pipe (Windows OpenSSH's
#      SSH_AUTH_SOCK). The guest side is persisted as an ONLOGON
#      scheduled task and auto-starts; the host side only lives for this
#      run.
#   4. Bridges the host's Docker engine the same way when one is running
#      (Docker Desktop, Colima, OrbStack, ...): host socat on TCP 4201,
#      guest Node relay serving \\.\pipe\docker_engine, docker context
#      'host' created and made the default, so `docker` and `docker
#      compose` in the guest hit the host engine. --no-docker skips.
#   5. Verifies that OpenChamber answers on http://127.0.0.1:4000 and
#      offers to open it in the browser.
#
# Not wired up (yet): the sandbox agent rules (scripts/agent-rules.md)
# are macOS-flavored and not installed into Windows guests; there is no
# shared host directory (the virtio-fs driver has no ARM64 Windows build,
# see images/windows-arm64-qemu/README.md) — use git, RDP clipboard, or
# the OpenChamber web UI instead.
#
# Environment (defaults in parentheses):
#   WINDOWS_IMAGE            path to a local sandbox-windows-11-arm64-qemu.qcow2 to
#                            run instead of the discovered/pulled one
#   SANDBOX_STATE_DIR        working VM state dir
#                            (~/Library/Application Support/agent-sandbox/windows-11-arm64-qemu)
#   WINDOWS_PASSWORD         Administrator password in the guest (read
#                            from the image's vars file; override after
#                            changing it in the guest)
#   SANDBOX_SSH_PORT         host port forwarded to guest SSH 22 (2222)
#   SANDBOX_RDP_PORT         host port forwarded to guest RDP 3389 (3389)
#   SANDBOX_WINRM_PORT       host port forwarded to guest WinRM 5985 (5985)
#   SANDBOX_OPENCHAMBER_PORT guest port of OpenChamber (4000)
#   SANDBOX_AGENT_PORT       TCP port for the SSH agent bridge (4200)
#   SANDBOX_DOCKER_PORT      TCP port for the Docker engine bridge (4201)
#   SANDBOX_CPU_COUNT        CPUs for the VM (from the vars file, 4)
#   SANDBOX_MEMORY_MB        RAM for the VM, in MB (from the vars file, 8192)
#   GHCR_OWNER               GHCR owner for pulls (default: from git remote)
#   NO_COLOR                 disable colored output (any non-empty value)
#
# Requires: Apple Silicon Mac, qemu + swtpm (brew install qemu swtpm),
# socat on the host (brew install socat) only when a bridge is needed,
# oras (brew install oras) only when pulling the image from GHCR, and
# expect (ships with macOS) for guest-side setup over SSH.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --- configuration ----------------------------------------------------------

image_name=sandbox-windows-11-arm64-qemu
platform_dir="$repo_root/images/windows-arm64-qemu"
vars_file="$platform_dir/vars/${image_name}.pkrvars.hcl"
host_state_dir="${SANDBOX_STATE_DIR:-$HOME/Library/Application Support/agent-sandbox/windows-11-arm64-qemu}"
agent_port=${SANDBOX_AGENT_PORT:-4200}
docker_port=${SANDBOX_DOCKER_PORT:-4201}
openchamber_port=${SANDBOX_OPENCHAMBER_PORT:-4000}
ssh_port=${SANDBOX_SSH_PORT:-2222}
rdp_port=${SANDBOX_RDP_PORT:-3389}
winrm_port=${SANDBOX_WINRM_PORT:-5985}

headless=0
detached=1
skip_agent=0
skip_docker=0
reset_vm=0

qemu_pid=
swtpm_pid=
bridge_pid=
docker_bridge_pid=
agent_bridged=0
guest_bridge_up=0
docker_bridged=0
docker_bridge_up=0
docker_engine_up=0
docker_server_version=
openchamber_up=0

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

# Per-image build directory, mirroring images/windows-arm64-qemu/build.sh:
# the local build output fallback lives in build/windows-arm64-qemu/.
build_dir="$repo_root/build/windows-arm64-qemu"

# --- step 1: prerequisites --------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command '$1' not found on PATH. Install with: $2"
}

ensure_prereqs() {
    [ "$(uname -s)" = "Darwin" ] || die "this script runs on macOS only."
    [ "$(uname -m)" = "arm64" ] || die "Apple Silicon required (QEMU + HVF can only virtualize ARM64 guests)."
    require_cmd qemu-system-aarch64 "brew install qemu"
    require_cmd qemu-img            "brew install qemu"
    require_cmd swtpm               "brew install swtpm"
    require_cmd curl                "comes with macOS"
    require_cmd expect              "comes with macOS"
    command -v socat >/dev/null 2>&1 ||
        warn "socat is not installed (brew install socat) — SSH agent and Docker bridges will be skipped."
}

# --- step 2: image selection ------------------------------------------------

# Prints the path of the qcow2 to run, pulling it when needed. The pristine
# image is only ever read (the working VM writes to a COW overlay).
pick_image() {
    if [ -n "${WINDOWS_IMAGE:-}" ]; then
        [ -f "$WINDOWS_IMAGE" ] || die "WINDOWS_IMAGE points to a file that does not exist: $WINDOWS_IMAGE"
        printf '%s\n' "$WINDOWS_IMAGE"
        return 0
    fi

    local_output="$build_dir/output/${image_name}.qcow2"
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
    cached="$host_state_dir/image/${image_name}.qcow2"
    if [ -f "$cached" ]; then
        printf '%s\n' "$cached"
        return 0
    fi

    command -v oras >/dev/null 2>&1 ||
        die "oras is not installed — needed to pull $registry:latest (brew install oras). Set WINDOWS_IMAGE to a local qcow2 to skip."
    if confirm "Pull $registry:latest (one-time, ~14 GB download)?" y; then
        mkdir -p "$host_state_dir/image"
        (cd "$host_state_dir/image" && oras pull "$registry:latest") ||
            die "oras pull failed — check your network connection (public GHCR images pull without a login)."
        [ -f "$cached" ] || die "oras pull produced no $cached — is the image published under $registry?"
        printf '%s\n' "$cached"
    else
        die "aborted — no sandbox image available. Set WINDOWS_IMAGE to a local qcow2 or pull manually."
    fi
}

# --- step 3: working VM state (overlay + TPM + EFI NVRAM) -------------------

# Creates the working VM state on first use (or --reset): a COW overlay
# over the pristine image, a persistent EFI NVRAM store, and a TPM state
# dir. The overlay records its backing image; when the backing image
# changes (e.g. a new build or pull), the overlay is recreated — otherwise
# Windows would read a corrupt disk.
ensure_working_vm() {
    overlay="$host_state_dir/${image_name}.qcow2"
    backing_marker="$host_state_dir/backing-image.txt"

    if [ "$reset_vm" = 1 ]; then
        info "Resetting the working VM (--reset) — deleting the overlay, TPM state, and EFI NVRAM."
        rm -rf "$host_state_dir"
    fi

    mkdir -p "$host_state_dir"

    # Identity of the pristine image: path + size + mtime. A rebuild (or a
    # new pull) replaces the file at the same path, so path alone would
    # silently stack the old overlay on a different base — a corrupt disk.
    pristine_id="$image_path|$(stat -f '%z' "$image_path")|$(stat -f '%m' "$image_path")"

    if [ -f "$overlay" ] && [ -f "$backing_marker" ] &&
        [ "$(cat "$backing_marker")" = "$pristine_id" ]; then
        ok "Working VM exists ($overlay)."
        return 0
    fi

    if [ -f "$overlay" ]; then
        warn "The backing image changed (new build or pull) — recreating the working VM."
        warn "Discarding the old overlay, EFI NVRAM, and TPM state (they belong to the previous image)."
        rm -f "$overlay"
        rm -f "$host_state_dir/efivars.fd"
        rm -rf "$host_state_dir/tpm"
    fi

    cmd "qemu-img create -f qcow2 -F qcow2 -b $image_path $overlay"
    qemu-img create -f qcow2 -F qcow2 -b "$image_path" "$overlay" >/dev/null
    printf '%s\n' "$pristine_id" >"$backing_marker"

    mkdir -p "$host_state_dir/tpm"

    # EFI NVRAM: prefer the vars store the image was built with (it holds
    # Windows' own Boot0000 for exactly this install); otherwise copy the
    # edk2 template and rely on the \EFI\BOOT\bootaa64.efi fallback the
    # installer writes (a fresh NVRAM has no Boot0000).
    if [ ! -f "$host_state_dir/efivars.fd" ]; then
        if [ -f "${image_path%/*}/efivars.fd" ]; then
            cp "${image_path%/*}/efivars.fd" "$host_state_dir/efivars.fd"
            info "EFI NVRAM: seeded from the build output's efivars.fd."
        else
            efi_template=/opt/homebrew/share/qemu/edk2-arm-vars.fd
            [ -f "$efi_template" ] ||
                die "EFI NVRAM template not found at $efi_template — is Homebrew's qemu installed?"
            cp "$efi_template" "$host_state_dir/efivars.fd"
        fi
    fi
    ok "Working VM created ($overlay)."
}

# --- step 4: boot the VM ----------------------------------------------------

# Stops a VM left running by a previous (detached) run. Must run before
# --reset and before a fresh boot — the old qemu would hold the overlay
# and its swtpm would hold the TPM state lock.
stop_running_vm() {
    qemu_pidfile="$host_state_dir/qemu.pid"
    if [ ! -f "$qemu_pidfile" ]; then
        return 0
    fi
    old=$(cat "$qemu_pidfile")
    if ! kill -0 "$old" 2>/dev/null; then
        return 0
    fi
    if ! confirm "The sandbox VM is already running (pid $old) — restart it?" n; then
        die "aborted — the VM is already running. Stop it with 'kill $old' and re-run."
    fi
    cmd "kill $old"
    kill "$old" || true
    n=0
    printf '%s' "    Waiting for the VM to stop"
    while kill -0 "$old" 2>/dev/null && [ "$n" -lt 30 ]; do
        printf '.'
        sleep 2
        n=$((n + 1))
    done
    printf ' %s\n' "${c_green}stopped${c_reset}"
    sleep 1
}

start_swtpm() {
    swtpm_sock="$host_state_dir/swtpm.sock"
    swtpm_pidfile="$host_state_dir/swtpm.pid"

    # A previous detached run may have left swtpm running (it holds a lock
    # on the TPM state dir — a fresh swtpm would fail to start). Stop it.
    if [ -f "$swtpm_pidfile" ]; then
        old=$(cat "$swtpm_pidfile")
        if kill -0 "$old" 2>/dev/null; then
            warn "stale swtpm (pid $old) still running — stopping it."
            kill "$old" 2>/dev/null || true
            sleep 1
        fi
    fi
    rm -f "$swtpm_sock" "$swtpm_pidfile"

    cmd "swtpm socket --tpm2 --tpmstate dir=$host_state_dir/tpm --ctrl type=unixio,path=$swtpm_sock"
    swtpm socket \
        --tpmstate "dir=$host_state_dir/tpm" \
        --ctrl "type=unixio,path=$swtpm_sock" \
        --log "file=$host_state_dir/swtpm.log,level=20" \
        --pid "file=$swtpm_pidfile" \
        --tpm2 \
        --daemon

    n=0
    while [ ! -S "$swtpm_sock" ] && [ "$n" -lt 10 ]; do
        sleep 1
        n=$((n + 1))
    done
    [ -S "$swtpm_sock" ] || die "swtpm socket $swtpm_sock did not appear (see $host_state_dir/swtpm.log)."
    swtpm_pid=$(cat "$swtpm_pidfile")
    ok "swtpm is up (pid $swtpm_pid)."
}

launch_qemu() {
    efi_code=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
    [ -f "$efi_code" ] || die "EFI firmware not found at $efi_code — is Homebrew's qemu installed?"

    # Same wiring the image was built with (qemu-with-tpm.sh), minus the
    # install media: virt machine, HVF, AAVMF UEFI, swtpm TPM 2.0 (ppi=off
    # avoids a QEMU 11.1 HVF regression), xhci + keyboard + tablet. The
    # disk is the COW overlay; user-mode networking forwards the guest
    # ports the image ships (SSH, RDP, OpenChamber, WinRM). The display is
    # virtio-gpu-pci, not the ramfb the image was *built* with: the
    # image's driver store contains the viogpudo (virtio-gpu display-only)
    # driver, so resizing the QEMU window changes the guest resolution
    # (VIRTIO_GPU_EVENT_DISPLAY), instead of just scaling the framebuffer.
    qemu_args=(
        -machine "virt,gic-version=max"
        -accel hvf
        -cpu host
        -smp "${cpu_count}"
        -m "${memory_mb}"
        -drive "if=pflash,format=raw,readonly=on,file=$efi_code"
        -drive "if=pflash,format=raw,file=$host_state_dir/efivars.fd"
        -drive "file=$overlay,if=virtio,format=qcow2"
        -device "virtio-net-pci,netdev=net0"
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22,hostfwd=tcp:127.0.0.1:${rdp_port}-:3389,hostfwd=tcp:127.0.0.1:${openchamber_port}-:${openchamber_port},hostfwd=tcp:127.0.0.1:${winrm_port}-:5985"
        -chardev "socket,id=chrtpm,path=$host_state_dir/swtpm.sock"
        -tpmdev "emulator,id=tpm0,chardev=chrtpm"
        -device "tpm-tis-device,tpmdev=tpm0,ppi=off"
        -device virtio-gpu-pci
        -device "qemu-xhci,id=usb"
        -device "usb-kbd,bus=usb.0"
        -device "usb-tablet,bus=usb.0"
    )
    if [ "$headless" = 1 ]; then
        qemu_args+=(-display none)
    else
        # zoom-to-fit=on: QEMU's cocoa window is created without the
        # resizable style mask unless this is set — it makes the window
        # draggable-resizable and scales the guest to fit (the View menu
        # can toggle it off, and Enter Fullscreen turns on full screen).
        qemu_args+=(-display cocoa,zoom-to-fit=on)
    fi

    qemu_log="$HOME/Library/Logs/agent-sandbox/qemu-windows-11.log"
    mkdir -p "${qemu_log%/*}"

    cmd "qemu-system-aarch64 ${qemu_args[*]}"
    if [ "$detached" = 1 ]; then
        info "Running the VM in the background (output: $qemu_log)."
        nohup qemu-system-aarch64 "${qemu_args[@]}" >>"$qemu_log" 2>&1 &
    else
        qemu-system-aarch64 "${qemu_args[@]}" >>"$qemu_log" 2>&1 &
    fi
    qemu_pid=$!
    printf '%s\n' "$qemu_pid" >"$host_state_dir/qemu.pid"

    wait_for_sshd "the VM to boot" 150
    ok "VM is up: SSH on 127.0.0.1:$ssh_port"
}

# Waits until the guest's sshd answers the BatchMode probe. The hostfwd
# listener binds the moment qemu starts, before the guest even boots — so
# probe for a real sshd instead of the port: with BatchMode (no password
# prompt), ssh answers "Permission denied" when the server is up,
# "Connection refused" before that. Output goes into a variable, not a
# pipe: grep -q would close the pipe on match, ssh would die of SIGPIPE
# (141), and pipefail would turn the probe into a failure.
wait_for_sshd() {
    label="$1"
    max="$2"

    ssh_ready() {
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -p "$ssh_port" "$guest_user@127.0.0.1" true 2>&1) || true
        case "$out" in
            *"Permission denied"*) return 0 ;;
        esac
        return 1
    }

    n=0
    printf '%s' "    Waiting for $label (up to $((max * 4 / 60)) min)"
    while [ "$n" -lt "$max" ]; do
        if [ -n "${qemu_pid:-}" ] && ! kill -0 "$qemu_pid" 2>/dev/null; then
            printf ' %s\n' "${c_yellow}failed${c_reset}"
            die "qemu exited before the VM booted — check $qemu_log."
        fi
        if ssh_ready; then
            printf ' %s\n' "${c_green}done${c_reset}"
            return 0
        fi
        n=$((n + 1))
        printf '.'
        sleep 4
    done
    printf ' %s\n' "${c_yellow}failed${c_reset}"
    die "timed out waiting for $label (no SSH on 127.0.0.1:$ssh_port). Check $qemu_log."
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
    GUEST_PS_B64="$b64" expect -c '
        set timeout 240
        set done 0
        set b64 $env(GUEST_PS_B64)
        spawn ssh -p '"$ssh_port"' -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=10 -o PreferredAuthentications=password \
            '"$guest_user"'@127.0.0.1 \
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

# Host-side listener: socat turns the local socket into a TCP port on the
# host loopback. The guest reaches the host loopback at 10.0.2.2 (QEMU
# user-mode networking), so the listener must not be bound to a specific
# interface beyond 127.0.0.1 — it is not exposed to the LAN.
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

    # Only a listener on the host loopback counts — the guest reaches the
    # host at 10.0.2.2, so a listener bound elsewhere (e.g. the macOS
    # runner's bridges on the Tart gateway) would not serve it.
    if lsof -nP -iTCP@127.0.0.1:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        ok "A listener is already bound to TCP port $port — assuming the bridge is up." >&2
        return 0
    fi

    cmd "socat TCP-LISTEN:$port,reuseaddr,fork,bind=127.0.0.1 -> $sock" >&2
    socat TCP-LISTEN:"$port",reuseaddr,fork,bind=127.0.0.1 UNIX-CONNECT:"$sock" >/dev/null 2>&1 &
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
    fi
    warn "host bridge exited immediately — check the socket path." >&2
    return 1
}

# Guest-side setup, rendered for the current bridge ports and sent as one
# idempotent PowerShell script. It does the whole job for both bridges:
#
#   - writes C:\tools\bridge-relay.js — a tiny Node relay that serves a
#     Windows named pipe and forwards every connection to a TCP endpoint.
#     Node is in the image, and net.createServer().listen('\\.\pipe\...')
#     is a native Windows named-pipe server, so no extra binaries are
#     needed. (npiperelay cannot do this: its -ep/-s flags are
#     EOF-handling options, and it only CONNECTS to existing pipes.)
#   - writes C:\tools\bridges.ps1 — the idempotent bridge logic (start the
#     relays, set SSH_AUTH_SOCK, docker context 'host');
#   - sets the execution policy to RemoteSigned (images since the
#     execution-policy fix bake in machine-wide RemoteSigned; this runtime
#     set is a fallback for images built before the fix, whose default
#     Restricted policy would block scripts from loading);
#   - registers an ONLOGON scheduled task that runs bridges.ps1 at every
#     logon (AutoAdminLogon fires it at boot) — and /Runs it right now.
#     The task is the detach mechanism: relays started from an ssh session
#     die when sshd tears the session down (its job kills the children),
#     while task-spawned processes live on.
#   - waits briefly, then reports a machine-readable status line:
#     installed | already-installed | docker-ok | docker-fail.
#
# Note: a plain heredoc into sed, not $(cat <<...) — macOS's default bash
# 3.2 misparses heredocs inside command substitution when the body contains
# backticks (the PowerShell here-strings below), while a plain quoted
# heredoc is literal in every bash.
render_guest_setup() {
    sed -e "s/__AGENT_PORT__/$agent_port/g" \
        -e "s/__DOCKER_PORT__/$docker_port/g" <<'GUEST_BRIDGE_PS'
$agentPort = __AGENT_PORT__
$dockerPort = __DOCKER_PORT__
$relay = 'C:\tools\bridge-relay.js'
$bridges = 'C:\tools\bridges.ps1'

# --- the Node relay: named pipe <-> TCP (in-image node.exe) ---
$relayScript = @'
var net = require('net');
var pipe = process.argv[2];
var host = process.argv[3];
var port = Number(process.argv[4]);
net.createServer(function (c) {
  var up = net.connect(port, host, function () {
    c.pipe(up);
    up.pipe(c);
  });
  c.on('error', function () { up.destroy(); });
  up.on('error', function () { c.destroy(); });
}).listen(pipe);
'@
if (-not (Test-Path $relay) -or (Get-Content $relay -Raw) -ne $relayScript) {
  Set-Content -Path $relay -Value $relayScript -Encoding UTF8
}

# --- the idempotent bridge logic, reused by the scheduled task ---
$bridgesScript = @'
$agentPort = __AGENT_PORT__
$dockerPort = __DOCKER_PORT__
$node = 'C:\Program Files\nodejs\node.exe'
$relay = 'C:\tools\bridge-relay.js'
function Ensure-Relay([string]$pipe, [int]$port) {
  $running = $false
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -like "*$relay*$pipe*") { $running = $true }
  }
  if (-not $running -and (Test-Path $relay) -and (Test-Path $node)) {
    Start-Process -WindowStyle Hidden -FilePath $node -ArgumentList @($relay, $pipe, '10.0.2.2', "$port")
  }
}
Ensure-Relay '\\.\pipe\openssh-ssh-agent' $agentPort
Ensure-Relay '\\.\pipe\docker_engine' $dockerPort
$current = [Environment]::GetEnvironmentVariable('SSH_AUTH_SOCK', 'User')
if ($current -ne '\\.\pipe\openssh-ssh-agent') {
  [Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK', '\\.\pipe\openssh-ssh-agent', 'User')
  $env:SSH_AUTH_SOCK = '\\.\pipe\openssh-ssh-agent'
}
if (Get-Command docker -ErrorAction SilentlyContinue) {
  docker context create host --docker "host=npipe:////./pipe/docker_engine" 2>$null | Out-Null
  docker context update host --docker "host=npipe:////./pipe/docker_engine" 2>$null | Out-Null
  docker context use host 2>$null | Out-Null
}
'@
if (-not (Test-Path $bridges) -or (Get-Content $bridges -Raw) -ne $bridgesScript) {
  Set-Content -Path $bridges -Value $bridgesScript -Encoding UTF8
}

# --- scripts (incl. the task's) must be able to load ---
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction SilentlyContinue

# --- the detached relay start: a SYSTEM ONCE task running a .cmd ---
# Relays started from an ssh session die when sshd tears the session down
# (its job kills the children). A SYSTEM task (run whether or not anyone
# is logged on) is outside that job, and ONCE tasks actually execute on
# manual /Run (ONLOGON tasks silently no-op).
$startRelays = 'C:\tools\start-relays.cmd'
$cmdScript = @'
@echo off
start "" /b "C:\Program Files\nodejs\node.exe" C:\tools\bridge-relay.js \\.\pipe\openssh-ssh-agent 10.0.2.2 __AGENT_PORT__
start "" /b "C:\Program Files\nodejs\node.exe" C:\tools\bridge-relay.js \\.\pipe\docker_engine 10.0.2.2 __DOCKER_PORT__
'@
Set-Content -Path $startRelays -Value $cmdScript -Encoding ASCII
schtasks /Create /TN agent-sandbox-relays /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F /TR $startRelays 2>$null | Out-Null
schtasks /Run /TN agent-sandbox-relays 2>$null | Out-Null

# --- scripts (incl. the task's) must be able to load ---
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction SilentlyContinue

# --- logon persistence (user context): ONLOGON task re-runs the logic ---
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\tools\bridges.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName 'agent-sandbox-bridges' -Action $action -Trigger $trigger -Force -ErrorAction SilentlyContinue | Out-Null

# --- user parts now (env var, docker context) — the relays were already
# started detached, so Ensure-Relay skips them ---
Start-Sleep -Seconds 3
& $bridges
$installed = 'installed'
$v = $null
for ($i = 0; $i -lt 20 -and -not $v; $i++) {
  Start-Sleep -Milliseconds 1000
  $v = docker info --format '{{.ServerVersion}}' 2>$null
}
if ($v) { $dockerStatus = "docker-ok:$v" } else { $dockerStatus = 'docker-fail' }
Write-Output "bridge-status:$installed;$dockerStatus"
GUEST_BRIDGE_PS
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
        info "Guest bridges not configured — the Node relays and the docker context must be set up manually (see docs/windows-qemu.md)."
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
        status=$(guest_ps "$(render_guest_setup)" 2>/dev/null | grep 'bridge-status:' | tail -n1) || true
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

# --- step 6: OpenChamber ----------------------------------------------------

verify_openchamber() {
    n=0
    printf '%s' "    Waiting for OpenChamber on http://127.0.0.1:$openchamber_port (up to 7 min)"
    while [ "$n" -lt 90 ]; do
        # perl alarm wrapper: macOS curl has been observed to hang past
        # --max-time on hostfwd connections the guest accepts but never
        # answers — alarm(4) kills it no matter what.
        code=$(perl -e 'alarm 4; exec @ARGV' curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 2 --max-time 3 \
            "http://127.0.0.1:$openchamber_port" 2>/dev/null) || true
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            printf ' %s\n' "${c_green}done${c_reset}"
            openchamber_up=1
            ok "OpenChamber is up: http://127.0.0.1:$openchamber_port (default password: sandbox)"
            if confirm "Open it in your browser now?" y; then
                open "http://127.0.0.1:$openchamber_port" 2>/dev/null ||
                    warn "could not open a browser — open http://127.0.0.1:$openchamber_port manually."
            fi
            return 0
        fi
        n=$((n + 1))
        printf '.'
        sleep 2
    done
    printf ' %s\n' "${c_yellow}failed${c_reset}"
    warn "OpenChamber did not respond on http://127.0.0.1:$openchamber_port within 7 min."
    warn "check it from inside the guest (RDP or SSH): openchamber status / openchamber logs"
    return 1
}

# --- summary ----------------------------------------------------------------

print_summary() {
    step "Sandbox is ready"
    printf '    %-14s %s\n' 'Image:' "$image_path"
    printf '    %-14s %s\n' 'SSH:' "ssh -p $ssh_port $guest_user@127.0.0.1 (password: $guest_password)"
    printf '    %-14s %s\n' 'RDP:' "127.0.0.1:$rdp_port ($guest_user / $guest_password)"
    printf '    %-14s %s\n' 'WinRM:' "127.0.0.1:$winrm_port (advanced use)"
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
        printf '    %-14s %s\n' 'OpenChamber:' "${c_green}http://127.0.0.1:$openchamber_port (password: sandbox)${c_reset}"
    else
        printf '    %-14s %s\n' 'OpenChamber:' "${c_yellow}not responding on http://127.0.0.1:$openchamber_port${c_reset}"
    fi
    printf '    %-14s %s\n' 'State:' "$host_state_dir (overlay + TPM + EFI NVRAM; --reset wipes it)"
    if [ "$detached" = 1 ] && [ -n "$qemu_pid" ]; then
        printf '    %-14s %s\n' 'Stop:' "./scripts/stop-windows-qemu-sandbox.sh (or: kill \$(cat $host_state_dir/qemu.pid))"
        printf '    %-14s %s\n' 'Background:' "VM keeps running after this script exits (qemu log: $qemu_log)"
        if [ "$agent_bridged" = 1 ]; then
            printf '    %-14s %s\n' 'Bridge:' "host socat on TCP $agent_port stays up — stop it with: ./scripts/stop-windows-qemu-sandbox.sh"
        fi
        if [ "$docker_bridged" = 1 ]; then
            printf '    %-14s %s\n' 'Bridge:' "host socat on TCP $docker_port stays up — stop it with: ./scripts/stop-windows-qemu-sandbox.sh"
        fi
    else
        printf '    %-14s %s\n' 'Stop:' 'press Cmd+C in this terminal'
    fi
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: run-windows-qemu-sandbox.sh [options]

Runs the Windows 11 (ARM64) sandbox VM under qemu-system-aarch64 and wires
up the SSH agent and Docker bridges.

By default the VM runs in the background: the script exits after the
summary and the VM keeps running (qemu log:
~/Library/Logs/agent-sandbox/qemu-windows-11.log).

Options:
  --headless     Run without a window (qemu -display none)
  --foreground   Keep the terminal attached and block until the VM stops
                 (Cmd+C in the terminal stops the VM)
  --no-agent     Skip the SSH agent bridge setup
  --no-docker    Skip the Docker engine bridge setup
  --reset        Delete the working VM state (overlay + TPM + EFI NVRAM)
                 and start fresh from the pristine image
  -h, --help     Show this help

Environment:
  WINDOWS_IMAGE              path to a local sandbox-windows-11-arm64-qemu.qcow2
  SANDBOX_STATE_DIR          working VM state dir
  WINDOWS_PASSWORD           Administrator password in the guest
  SANDBOX_SSH_PORT           host port for guest SSH (2222)
  SANDBOX_RDP_PORT           host port for guest RDP (3389)
  SANDBOX_WINRM_PORT         host port for guest WinRM (5985)
  SANDBOX_OPENCHAMBER_PORT   guest port of OpenChamber (4000)
  SANDBOX_AGENT_PORT         TCP port for the SSH agent bridge (4200)
  SANDBOX_DOCKER_PORT        TCP port for the Docker engine bridge (4201)
  SANDBOX_CPU_COUNT          CPUs for the VM (from the vars file)
  SANDBOX_MEMORY_MB          RAM for the VM, in MB (from the vars file)
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
        --reset) reset_vm=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

# Foreground mode: tear down what this run started when the script exits
# (Cmd+C kills the script group, taking qemu with it; swtpm and the host
# bridges must be stopped explicitly). Background mode leaves everything
# up — the VM and its bridges outlive this script by design.
cleanup() {
    if [ "$detached" = 0 ] && [ -n "$qemu_pid" ]; then
        if [ -n "$docker_bridge_pid" ]; then
            kill "$docker_bridge_pid" 2>/dev/null || true
            info "Stopped the host Docker bridge (pid $docker_bridge_pid)."
        fi
        if [ -n "$bridge_pid" ]; then
            kill "$bridge_pid" 2>/dev/null || true
            info "Stopped the host socat bridge (pid $bridge_pid)."
        fi
        if [ -n "$swtpm_pid" ]; then
            kill "$swtpm_pid" 2>/dev/null || true
            info "Stopped swtpm (pid $swtpm_pid)."
        fi
    fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

title "Windows sandbox: $image_name"

# 0. Prerequisites.
ensure_prereqs

# Credentials and resources come from the image's vars file (single source
# of truth; WINDOWS_PASSWORD overrides after changing it in the guest).
[ -f "$vars_file" ] || die "vars file not found: $vars_file"
guest_user=$(read_var winrm_username)
[ -n "$guest_user" ] || guest_user=Administrator
guest_password=${WINDOWS_PASSWORD:-$(read_var winrm_password)}
[ -n "$guest_password" ] || die "could not read winrm_password from $vars_file"
cpu_count=${SANDBOX_CPU_COUNT:-$(read_var cpu_count)}
memory_mb=${SANDBOX_MEMORY_MB:-$(read_var memory_gb)}
[ -n "$cpu_count" ] || cpu_count=4
if [ -z "$memory_mb" ]; then memory_mb=8192; else memory_mb=$((memory_mb * 1024)); fi

# Stop a VM left running by a previous run before touching the state dir
# (--reset would otherwise delete files a live qemu/swtpm still hold).
step "Step 0/5: Running VM check"
stop_running_vm

# 1. Pick the image (local build output, env override, or GHCR pull).
step "Step 1/5: Sandbox image"
image_path=$(pick_image)
ok "Using image: $image_path"

# 2. Working VM state (COW overlay + persistent TPM/NVRAM).
step "Step 2/5: Working VM state"
ensure_working_vm

# 3. Boot (+ one-time auto-logon so the OpenChamber task fires at boot).
step "Step 3/5: Starting the VM"
start_swtpm
launch_qemu
ensure_autologon

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

# 4. Guest-side bridges (Node relay named pipes + docker context), over SSH.
step "Step 4/5: Guest bridges"
if [ "$skip_agent" = 1 ] && [ "$skip_docker" = 1 ]; then
    info "Both bridges skipped — nothing to set up in the guest."
elif [ "$agent_bridged" = 0 ] && [ "$docker_bridged" = 0 ]; then
    info "No host bridges needed (no SSH agent override, no Docker engine) — nothing to set up in the guest."
else
    setup_guest_bridges
fi

# 5. Verify OpenChamber and offer to open it.
step "Step 5/5: OpenChamber"
verify_openchamber || true

print_summary

# Foreground mode: keep the terminal attached until the VM stops. Cmd+C
# kills the script group, which takes qemu down with it; the EXIT trap
# cleans up swtpm and the host bridges. In background mode everything
# stays up — the VM and its bridges outlive this script by design.
if [ "$detached" = 0 ] && [ -n "$qemu_pid" ]; then
    if wait "$qemu_pid"; then
        info "VM stopped."
    else
        warn "VM exited with an error (see $qemu_log)."
    fi
fi
