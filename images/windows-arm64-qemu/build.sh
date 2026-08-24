#!/bin/bash
# images/windows-arm64-qemu/build.sh — build the Windows sandbox images (Packer qemu).
#
# Invoked by scripts/build.sh, which delegates to a platform's build.sh
# wrapper when one exists. The plain `packer init && packer build` flow of
# the macOS images cannot build Windows, for three reasons:
#
#   1. The Windows 11 ARM64 ISO is bring-your-own — Microsoft does not
#      permit redistribution, so the file lives on the build host and is
#      referenced via WINDOWS_ISO_PATH, not committed.
#   2. WinPE needs the ARM64 virtio drivers (viostor / vioscsi / NetKVM)
#      staged into the same CD as autounattend.xml; they are extracted
#      here from virtio-win.iso into
#      build/windows-arm64-qemu/drivers/staging/.
#   3. Windows 11 requires a TPM 2.0 — swtpm must run while Packer boots
#      the VM, and Packer's qemu binary must be wrapped by
#      qemu-with-tpm.sh (the plugin's qemuargs option replaces its
#      generated args instead of appending).
#
# Usage:
#   images/windows-arm64-qemu/build.sh [<image>]
#
# <image> defaults to the single vars file in vars/ (must be passed when
# more than one image exists).
#
# Environment:
#   WINDOWS_ISO_PATH    — path to the Windows 11 ARM64 ISO (required;
#                         verified against iso_sha256 from the vars file)
#   VIRTIO_WIN_ISO_PATH — path to virtio-win.iso (optional; downloaded
#                         from the vars file's virtio_win_url into
#                         build/windows-arm64-qemu/packer_cache/ when unset)
#   PACKER_LOG          — 1 for verbose Packer output
#
# Build layout: every image gets its own directory under
# build/windows-arm64-qemu/ — output/ (the built qcow2), packer_cache/
# (virtio-win.iso, swtpm state, watchdog frames/log) and
# drivers/staging/ (driver subset packed into the unattend CD). The tart
# (macOS) images build no files and have no such directory.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
platform_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# ---- image / vars resolution ----------------------------------------------

requested="${1:-}"
if [ -n "$requested" ]; then
  image_name="$requested"
else
  vars_files=("$platform_dir"/vars/*.pkrvars.hcl)
  if [ "${#vars_files[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one vars file in $platform_dir/vars/," >&2
    echo "       pass the image name explicitly (e.g. sandbox-windows-11)." >&2
    exit 1
  fi
  image_name=$(basename "${vars_files[0]}" .pkrvars.hcl)
fi
vars_file="$platform_dir/vars/${image_name}.pkrvars.hcl"
if [ ! -f "$vars_file" ]; then
  echo "ERROR: expected $vars_file (image name = vars file name)." >&2
  exit 1
fi

# ---- host preconditions ----------------------------------------------------

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "ERROR: the Windows image can only be built on Apple Silicon (QEMU + HVF)." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command '$1' not found on PATH." >&2
    echo "       Install with: $2" >&2
    exit 1
  }
}

require_cmd packer              "brew install packer"
require_cmd qemu-system-aarch64 "brew install qemu"
require_cmd qemu-img            "brew install qemu"
require_cmd swtpm               "brew install swtpm"
require_cmd curl                "comes with macOS"
require_cmd hdiutil             "comes with macOS"
require_cmd xmllint             "comes with macOS"

# ---- vars file helpers -----------------------------------------------------
#
# Same sed pattern as scripts/deploy.sh: pulls a quoted string variable
# out of the vars file.

read_var() {
  sed -n \
    "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\"[[:space:]]*$/\1/p" \
    "$vars_file"
}

iso_sha256=$(read_var iso_sha256)
virtio_win_url=$(read_var virtio_win_url)
virtio_win_sha256=$(read_var virtio_win_sha256)

# ---- per-image build directory --------------------------------------------
#
# Built images and their scratch live under build/windows-arm64-qemu/
# (gitignored):
#   output/          — Packer's output_directory (the built qcow2)
#   packer_cache/    — virtio-win.iso, swtpm state, watchdog frames/logs
#   drivers/staging/ — ARM64 virtio drivers packed into the unattend CD
#
# Note: do NOT pre-create output_dir — the qemu plugin refuses an existing
# output directory (it creates it itself; use `packer build -force` to
# rebuild over an old artifact).

build_dir="$repo_root/build/windows-arm64-qemu"
output_dir="$build_dir/output"
cache_dir="$build_dir/packer_cache"
staging_dir="$build_dir/drivers/staging"
mkdir -p "$cache_dir"

# ---- Windows ISO (bring-your-own) ------------------------------------------

if [ -z "${WINDOWS_ISO_PATH:-}" ]; then
  echo "ERROR: WINDOWS_ISO_PATH is not set." >&2
  echo "       Download the Windows 11 ARM64 ISO from" >&2
  echo "       https://www.microsoft.com/software-download/windows11arm64," >&2
  echo "       then set WINDOWS_ISO_PATH to its absolute path." >&2
  echo "       Paste the SHA256 from the download page into iso_sha256 in" >&2
  echo "       $vars_file to enable integrity verification." >&2
  exit 1
fi
if [ ! -f "$WINDOWS_ISO_PATH" ]; then
  echo "ERROR: WINDOWS_ISO_PATH points to a file that does not exist:" >&2
  echo "       $WINDOWS_ISO_PATH" >&2
  exit 1
fi

if [ -n "$iso_sha256" ]; then
  echo "==> verifying SHA256 of $(basename "$WINDOWS_ISO_PATH")"
  expected=$(printf '%s' "$iso_sha256" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  actual=$(shasum -a 256 "$WINDOWS_ISO_PATH" | awk '{print $1}')
  if [ "$expected" != "$actual" ]; then
    echo "ERROR: SHA256 mismatch for the Windows ISO." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    echo "  Re-download the ISO or update iso_sha256 in $vars_file." >&2
    exit 1
  fi
else
  echo "WARN: iso_sha256 is empty in $vars_file — skipping ISO verification." >&2
fi

# ---- virtio-win.iso (ARM64 drivers) -----------------------------------------
#
# Release 0.1.240+ ships ARM64 binaries; older releases fail later with
# "ARM64 driver tree missing".

if [ -z "${VIRTIO_WIN_ISO_PATH:-}" ]; then
  echo "==> VIRTIO_WIN_ISO_PATH unset — downloading virtio-win.iso"
  mkdir -p "$cache_dir"
  VIRTIO_WIN_ISO_PATH="$cache_dir/virtio-win.iso"
  if [ ! -f "$VIRTIO_WIN_ISO_PATH" ]; then
    curl -fSL -o "$VIRTIO_WIN_ISO_PATH" "$virtio_win_url"
  else
    echo "    already cached: $VIRTIO_WIN_ISO_PATH"
  fi
  if [ -n "$virtio_win_sha256" ]; then
    expected=$(printf '%s' "$virtio_win_sha256" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    actual=$(shasum -a 256 "$VIRTIO_WIN_ISO_PATH" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
      echo "ERROR: SHA256 mismatch for virtio-win.iso." >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      echo "  Delete $VIRTIO_WIN_ISO_PATH and rebuild, or update" >&2
      echo "  virtio_win_sha256 in $vars_file." >&2
      exit 1
    fi
  fi
fi
if [ ! -f "$VIRTIO_WIN_ISO_PATH" ]; then
  echo "ERROR: VIRTIO_WIN_ISO_PATH points to a file that does not exist:" >&2
  echo "       $VIRTIO_WIN_ISO_PATH" >&2
  exit 1
fi

# ---- driver staging: ARM64 virtio drivers into the unattend CD ------------

mount_dir=$(mktemp -d -t agent-sandbox-virtio-win.XXXXXX)
swtpm_pidfile=""
cleanup() {
  stop_watchdog
  hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
  rmdir "$mount_dir" 2>/dev/null || true
  if [ -f "$swtpm_pidfile" ]; then
    kill "$(cat "$swtpm_pidfile")" 2>/dev/null || true
    rm -f "$swtpm_pidfile"
  fi
}
trap cleanup EXIT

echo "==> mounting $(basename "$VIRTIO_WIN_ISO_PATH")"
hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$VIRTIO_WIN_ISO_PATH" >/dev/null

rm -rf "$staging_dir"
mkdir -p "$staging_dir"

# Drivers WinPE needs at install time: viostor (virtio-blk — the boot
# disk), vioscsi (belt-and-braces for virtio-scsi) and NetKVM (the NIC —
# without it the FirstLogonCommands network step hangs forever).
winpe_drivers=(viostor vioscsi NetKVM)
missing=()
for d in "${winpe_drivers[@]}"; do
  src="$mount_dir/$d/w11/ARM64"
  if [ ! -d "$src" ]; then
    missing+=("$d")
    continue
  fi
  mkdir -p "$staging_dir/$d"
  cp -R "$src/." "$staging_dir/$d/"
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: ARM64 driver tree missing from virtio-win.iso for:" >&2
  echo "       ${missing[*]}" >&2
  echo "       Expected <driver>/w11/ARM64/ to exist. Your virtio-win.iso" >&2
  echo "       may pre-date 0.1.240 (the first release with ARM64 builds)." >&2
  exit 1
fi

hdiutil detach "$mount_dir" -quiet || true
rmdir "$mount_dir" 2>/dev/null || true

# ---- swtpm (TPM 2.0 emulator) ----------------------------------------------
#
# Windows 11's system-requirements check refuses to install without a
# TPM 2.0. swtpm provides one over a Unix socket; qemu-with-tpm.sh wires
# it in. State is wiped per build (nothing to carry forward).

swtpm_dir="$cache_dir/swtpm"
swtpm_sock="$swtpm_dir/sock"
swtpm_pidfile="$swtpm_dir/pid"

mkdir -p "$swtpm_dir"
rm -f "$swtpm_sock" "$swtpm_pidfile"
rm -rf "$swtpm_dir/tpm2-00.permall" 2>/dev/null || true

echo "==> starting swtpm (TPM 2.0 emulator)"
swtpm socket \
  --tpmstate "dir=$swtpm_dir" \
  --ctrl "type=unixio,path=$swtpm_sock" \
  --log "file=$swtpm_dir/log,level=20" \
  --pid "file=$swtpm_pidfile" \
  --tpm2 \
  --daemon

sleep 1
if [ ! -S "$swtpm_sock" ]; then
  echo "ERROR: swtpm socket $swtpm_sock did not appear." >&2
  echo "       Check $swtpm_dir/log." >&2
  exit 1
fi

# ---- build watchdog (VNC) ---------------------------------------------------
#
# The headless build's boot_command Enter-spam can hit "Cancel" on Windows
# Setup's "Installing Windows 11" screen, and boot races can land in the
# UEFI shell — either way the build stalls until something answers. The
# watchdog (scripts/watch-build.sh) polls the VNC framebuffer the plugin
# exposes (pinned to port 5901 in sandbox.pkr.hcl), OCRs each frame, and
# auto-dismisses the dialogs. Optional but strongly recommended: without
# it, rebuilds can stall mid-Setup.

watchdog_pid=""
start_watchdog() {
  if ! python3 -c 'import vncdotool' 2>/dev/null; then
    echo "WARN: vncdotool not installed (pip3 install vncdotool) —" >&2
    echo "      the build may stall at Setup dialogs without the watchdog." >&2
    return 1
  fi
  command -v swiftc >/dev/null 2>&1 || {
    echo "WARN: swiftc not found — the watchdog OCR helper needs the" >&2
    echo "      Xcode command line tools; skipping the watchdog." >&2
    return 1
  }
  echo "==> starting build watchdog (VNC port 5901, frames in $cache_dir/watchdog)"
  "$repo_root/scripts/watch-build.sh" 5901 "$cache_dir/watchdog" \
    >"$cache_dir/watchdog.log" 2>&1 &
  watchdog_pid=$!
}

stop_watchdog() {
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  fi
}

# ---- packer pipeline ---------------------------------------------------------

export SWTPM_SOCK="$swtpm_sock"
export VIRTIO_WIN_ISO_PATH
export QEMU_WITH_TPM_LOG="$cache_dir/qemu-with-tpm.cmd.log"
export PKR_VAR_iso_path="$WINDOWS_ISO_PATH"
export PKR_VAR_virtio_win_iso_path="$VIRTIO_WIN_ISO_PATH"
export PKR_VAR_qemu_binary="$platform_dir/qemu-with-tpm.sh"

echo "==> xmllint autounattend.xml"
xmllint --noout "$platform_dir/autounattend.xml"

echo "==> packer init"
packer init "$platform_dir/sandbox.pkr.hcl"

echo "==> packer fmt -check"
packer fmt -check "$platform_dir" || {
  echo "WARN: 'packer fmt' would change formatting. Run 'packer fmt $platform_dir' to fix." >&2
}

echo "==> packer build"
start_watchdog
# Don't `exec` — the EXIT trap must tear down swtpm, the ISO mount, and
# the watchdog.
(
  cd "$platform_dir" &&
    packer build \
      -var "build_dir=$build_dir" \
      -var-file="$vars_file" "$platform_dir/sandbox.pkr.hcl"
)
stop_watchdog

# ---- compress the output -----------------------------------------------------

output="$output_dir/${image_name}.qcow2"
if [ ! -f "$output" ]; then
  echo "ERROR: build produced no $output" >&2
  exit 1
fi

echo "==> compressing $output (zstd)"
qemu-img convert -c -O qcow2 -o compression_type=zstd "$output" "$output.tmp"
mv "$output.tmp" "$output"
qemu-img info "$output" | grep -E "virtual size|disk size"

echo "Done: $output"
