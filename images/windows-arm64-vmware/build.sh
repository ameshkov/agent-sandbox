#!/bin/bash
# images/windows-arm64-vmware/build.sh — build the Windows sandbox images
# (Packer vmware-iso on VMware Fusion).
#
# Invoked by scripts/build.sh, which delegates to a platform's build.sh
# wrapper when one exists. The plain `packer init && packer build` flow of
# the macOS images cannot build Windows, for three reasons:
#
#   1. The Windows 11 ARM64 ISO is bring-your-own — Microsoft does not
#      permit redistribution, so the file lives on the build host and is
#      referenced via WINDOWS_ISO_PATH, not committed.
#   2. WinPE/installed-OS needs the ARM64 vmxnet3 NIC driver — VMware
#      Fusion ships it in Contents/Library/isoimages/arm64/
#      drivers-arm64.zip; it is extracted here into
#      build/windows-arm64-vmware/drivers/staging/ and packed into the
#      same CD as autounattend.xml (FirstLogonCommands installs it before
#      any network use).
#   3. The VMware Tools ARM64 ISO (also inside the Fusion app) must exist
#      for the template's tools_mode "attach" — the tools let the sandbox
#      runner discover the guest IP (vmrun getGuestIPAddress).
#
# Usage:
#   images/windows-arm64-vmware/build.sh [<image>]
#
# <image> defaults to the single vars file in vars/ (must be passed when
# more than one image exists).
#
# Environment:
#   WINDOWS_ISO_PATH  — path to the Windows 11 ARM64 ISO (required;
#                       verified against iso_sha256 from the vars file)
#   FUSION_APP_PATH   — path to the VMware Fusion installation (default:
#                       /Applications/VMware Fusion.app)
#   PACKER_LOG        — 1 for verbose Packer output

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
    echo "       pass the image name explicitly (e.g. sandbox-windows-11-vmware)." >&2
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
  echo "ERROR: the Windows image can only be built on Apple Silicon (VMware" >&2
  echo "       Fusion cannot run ARM64 guests on Intel Macs)." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command '$1' not found on PATH." >&2
    echo "       Install with: $2" >&2
    exit 1
  }
}

require_cmd packer  "brew install packer"
require_cmd unzip   "comes with macOS"
require_cmd xmllint "comes with macOS"

fusion_app_path="${FUSION_APP_PATH:-}"
if [ -z "$fusion_app_path" ]; then
  fusion_app_path=$(sed -n \
    's/^[[:space:]]*vmware_fusion_app_path[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
    "$vars_file")
fi
fusion_app_path="${fusion_app_path:-/Applications/VMware Fusion.app}"
if [ ! -d "$fusion_app_path" ]; then
  echo "ERROR: VMware Fusion not found at $fusion_app_path." >&2
  echo "       Install VMware Fusion (free, Broadcom) or set FUSION_APP_PATH." >&2
  exit 1
fi
echo "==> using VMware Fusion at $fusion_app_path"

drivers_zip="$fusion_app_path/Contents/Library/isoimages/arm64/drivers-arm64.zip"
tools_iso="$fusion_app_path/Contents/Library/isoimages/arm64/windows.iso"
if [ ! -f "$drivers_zip" ]; then
  echo "ERROR: ARM64 boot drivers not found at $drivers_zip." >&2
  echo "       This Fusion version does not ship the ARM64 Windows drivers —" >&2
  echo "       use Fusion 13.6+ (checked from the app bundle)." >&2
  exit 1
fi
if [ ! -f "$tools_iso" ]; then
  echo "ERROR: ARM64 VMware Tools ISO not found at $tools_iso." >&2
  echo "       This Fusion version does not ship ARM64 tools —" >&2
  echo "       use Fusion 13.6+ (checked from the app bundle)." >&2
  exit 1
fi

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

# ---- per-image build directory --------------------------------------------
#
# Built images and their scratch live under build/windows-arm64-vmware/
# (gitignored):
#   output/          — Packer's output_directory (vmx + vmdk + nvram)
#   packer_cache/    — watchdog frames/logs
#   drivers/staging/ — vmxnet3 ARM64 drivers packed into the unattend CD
#
# Note: do NOT pre-create output_dir — Packer's vmware-iso builder owns it
# (use `packer build -force` to rebuild over an old artifact).

build_dir="$repo_root/build/windows-arm64-vmware"
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

# ---- driver staging: vmxnet3 ARM64 into the unattend CD ---------------------
#
# Windows 11 ARM64 has no in-box VMware NIC driver. The installed OS needs
# vmxnet3 BEFORE any network use (WinRM from the host); WinPE itself is
# offline, so no WinPE driver is staged (the NVMe disk driver is in-box).
# Only the inf/sys/cat trio is needed — extracted flat at the CD root.

echo "==> staging vmxnet3 ARM64 drivers into $staging_dir"
rm -rf "$staging_dir"
mkdir -p "$staging_dir"

if ! unzip -jo "$drivers_zip" "vmxnet3/Win10_1709/ARM64/vmxnet3.cat" \
    "vmxnet3/Win10_1709/ARM64/vmxnet3.inf" \
    "vmxnet3/Win10_1709/ARM64/vmxnet3.sys" \
    -d "$staging_dir" >/dev/null; then
  echo "ERROR: vmxnet3 ARM64 driver missing from $drivers_zip." >&2
  echo "       Expected vmxnet3/Win10_1709/ARM64/vmxnet3.{inf,sys,cat}." >&2
  exit 1
fi

# ---- build watchdog (VNC) ---------------------------------------------------
#
# The headless build's boot_command Enter presses can land in the UEFI
# shell or Windows Setup dialogs; the watchdog (scripts/watch-build.sh)
# polls the VNC framebuffer the plugin exposes (pinned to port 5901 in
# sandbox.pkr.hcl), OCRs each frame, and auto-dismisses the dialog/shell.
# Optional but strongly recommended: without it, rebuilds can stall
# mid-Setup.

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
  mkdir -p "$cache_dir"
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

cleanup() {
  stop_watchdog
}
trap cleanup EXIT

# ---- packer pipeline ---------------------------------------------------------

export PKR_VAR_iso_path="$WINDOWS_ISO_PATH"
export PKR_VAR_vmware_fusion_app_path="$fusion_app_path"

echo "==> xmllint autounattend.xml"
xmllint --noout "$platform_dir/autounattend.xml"

echo "==> packer init"
packer init "$platform_dir/sandbox.pkr.hcl"

echo "==> packer fmt -check"
packer fmt -check "$platform_dir" || {
  echo "WARN: 'packer fmt' would change formatting. Run 'packer fmt $platform_dir' to fix." >&2
}

echo "==> packer build"
start_watchdog || true
(
  cd "$platform_dir" &&
    packer build \
      -var "build_dir=$build_dir" \
      -var-file="$vars_file" "$platform_dir/sandbox.pkr.hcl"
)
stop_watchdog

# ---- verify the output --------------------------------------------------------

output="$output_dir/${image_name}.vmx"
if [ ! -f "$output" ]; then
  echo "ERROR: build produced no $output" >&2
  echo "       Expected the vmware-iso builder's export in $output_dir/." >&2
  exit 1
fi

# ---- upgrade the artifact to the host Fusion's hardware version -------------
#
# The builder writes the VM at hardware version 20; starting such a VM
# under a newer Fusion shows a one-time "Upgrade this virtual machine?"
# prompt on the FIRST GUI (Fusion window) start — headless vmrun starts
# are unaffected, which is why the build itself never hits it. Upgrade the
# output VM right after the build so the published artifact is at the
# hardware level the building Fusion would write. The sandbox runner
# upgrades its working clone the same way (for artifacts that were built
# by older Fusion versions; see scripts/lib/windows-vmware/lib.sh).

export FUSION_APP_PATH="${FUSION_APP_PATH:-$fusion_app_path}"
source "$repo_root/scripts/lib/windows-vmware/lib.sh"
before=$(vmware_hw_version "$output") || before=""
after=$(upgrade_vm_hardware "$output" "build output") || after=""
if [ -n "$after" ] && [ -n "$before" ] && [ "$after" != "$before" ]; then
  echo "==> build output upgraded to hardware version $after"
else
  echo "==> build output hardware version: ${after:-unknown}"
fi

echo "==> build output"
du -sh "$output_dir"
echo "Done: $output (export with ./scripts/deploy.sh $image_name)"
