#!/bin/bash
# images/ubuntu-arm64-vmware/build.sh — build the Ubuntu sandbox images
# (Packer vmware-iso on VMware Fusion).
#
# Invoked by scripts/build.sh, which delegates to a platform's build.sh
# wrapper when one exists. The plain `packer init && packer build` flow of
# the macOS images cannot build Ubuntu, for three reasons:
#
#   1. The Ubuntu Server ARM64 ISO is bring-your-own — Canonical builds it
#      fresh per point release (~3 GB, not redistributable in the repo), so
#      the file lives on the build host and is referenced via
#      UBUNTU_ISO_PATH, not committed.
#   2. The ISO hash is verified here (the template's iso_checksum is
#      "none"), and the ISO hash is also what makes the autoinstall
#      deterministic: the installer kernel is given
#      'autoinstall ds=nocloud-net;s=http://<host>:<port>/' by the
#      boot_command (no waits, so the grub typing cannot overrun the
#      30 s menu auto-boot), and the seed is served by Packer's HTTP
#      server.
#   3. The built artifact — a vmx + vmdk VM at the vmware-iso hardware
#      level — is upgraded to the host Fusion's hardware version with
#      `vmrun upgradevm` (shared helper scripts/lib/vmware.sh).
#
# Unlike the Windows build there is no driver staging (Ubuntu's kernel has
# vmxnet3 + NVMe in-box) and no tools ISO from Fusion (Fusion ships no
# Linux tools for arm64 guests — open-vm-tools come from the Ubuntu
# archive).
#
# Usage:
#   images/ubuntu-arm64-vmware/build.sh [<image>]
#
# <image> defaults to the single vars file in vars/ (must be passed when
# more than one image exists).
#
# Environment:
#   UBUNTU_ISO_PATH  — path to the Ubuntu Server 24.04 ARM64 ISO
#                      (https://cdimage.ubuntu.com/releases/24.04/release/;
#                      required, verified against iso_sha256 from the vars
#                      file)
#   FUSION_APP_PATH  — path to the VMware Fusion installation (default:
#                      /Applications/VMware Fusion.app)
#   PACKER_LOG       — 1 for verbose Packer output

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
    echo "       pass the image name explicitly (e.g. sandbox-ubuntu-24-04-arm64-vmware)." >&2
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
  echo "ERROR: the Ubuntu image can only be built on Apple Silicon (VMware" >&2
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

require_cmd packer "brew install packer"

# ---- autoinstall seed server ------------------------------------------------
#
# The seed (autoinstall/user-data + meta-data) is served by the wrapper's
# own HTTP server on a fixed port. The vmware plugin's http_directory uses
# a random port and does not accept an http_port override, and the
# autoinstall URL must be known when the watchdog types it into grub (see
# the watchdog note below). The guest reaches the server at the vmnet8
# host address — x.y.z.1 of the NAT subnet (read from Fusion's vmnet8
# DHCP config; vmnetd delivers guest traffic to that address into the
# host's loopback, which the bridge runners rely on too).

seed_server_pid=""
seed_port=8004
start_seed_server() {
  if lsof -nP -iTCP:"$seed_port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port $seed_port is taken (something else is listening)." >&2
    echo "       Stop the other listener or change seed_port in build.sh." >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required to serve the autoinstall seed." >&2
    exit 1
  }
  echo "==> serving the autoinstall seed at http://<host>:$seed_port/ (autoinstall/ dir)"
  python3 -m http.server "$seed_port" --bind 0.0.0.0 \
    --directory "$platform_dir/autoinstall" \
    >"$cache_dir/seed-server.log" 2>&1 &
  seed_server_pid=$!
  sleep 1
  kill -0 "$seed_server_pid" 2>/dev/null || {
    echo "ERROR: the seed server exited — see $cache_dir/seed-server.log." >&2
    exit 1
  }
}

stop_seed_server() {
  if [ -n "$seed_server_pid" ]; then
    kill "$seed_server_pid" 2>/dev/null || true
    wait "$seed_server_pid" 2>/dev/null || true
    seed_server_pid=""
  fi
}

# ---- vmrun (Fusion) for the post-build hardware-version upgrade --------------
# A missing Fusion is not fatal (the build itself works) but the artifact
# would keep the builder's hardware level and prompt once on a GUI start.
export FUSION_APP_PATH="${FUSION_APP_PATH:-/Applications/VMware Fusion.app}"
if [ ! -d "$FUSION_APP_PATH" ]; then
  echo "WARN: VMware Fusion not found at $FUSION_APP_PATH —" >&2
  echo "      the post-build hardware upgrade will be skipped." >&2
  echo "      Install VMware Fusion (free, Broadcom) or set FUSION_APP_PATH." >&2
  FUSION_APP_PATH=""
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
# Built images and their scratch live under build/ubuntu-arm64-vmware/
# (gitignored):
#   output/       — Packer's output_directory (vmx + vmdk + nvram)
#   packer_cache/ — watchdog frames/logs
#
# Note: do NOT pre-create output_dir — Packer's vmware-iso builder owns it
# (use `packer build -force` to rebuild over an old artifact).

build_dir="$repo_root/build/ubuntu-arm64-vmware"
output_dir="$build_dir/output"
cache_dir="$build_dir/packer_cache"
mkdir -p "$cache_dir"

# ---- Ubuntu ISO (bring-your-own) -------------------------------------------

if [ -z "${UBUNTU_ISO_PATH:-}" ]; then
  echo "ERROR: UBUNTU_ISO_PATH is not set." >&2
  echo "       Download the Ubuntu Server 24.04 ARM64 ISO (live-server-arm64)" >&2
  echo "       from https://cdimage.ubuntu.com/releases/24.04/release/," >&2
  echo "       then set UBUNTU_ISO_PATH to its absolute path." >&2
  echo "       Paste the SHA256 from the release SHA256SUMS into iso_sha256 in" >&2
  echo "       $vars_file to enable integrity verification." >&2
  exit 1
fi
if [ ! -f "$UBUNTU_ISO_PATH" ]; then
  echo "ERROR: UBUNTU_ISO_PATH points to a file that does not exist:" >&2
  echo "       $UBUNTU_ISO_PATH" >&2
  exit 1
fi

if [ -n "$iso_sha256" ]; then
  echo "==> verifying SHA256 of $(basename "$UBUNTU_ISO_PATH")"
  expected=$(printf '%s' "$iso_sha256" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  actual=$(shasum -a 256 "$UBUNTU_ISO_PATH" | awk '{print $1}')
  if [ "$expected" != "$actual" ]; then
    echo "ERROR: SHA256 mismatch for the Ubuntu ISO." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    echo "  Re-download the ISO or update iso_sha256 in $vars_file." >&2
    exit 1
  fi
else
  echo "WARN: iso_sha256 is empty in $vars_file — skipping ISO verification." >&2
fi

# ---- build watchdog (VNC) ---------------------------------------------------
#
# The headless build's boot_command sends the autoinstall kernel line
# through grub; the installer later shows screens the watchdog can
# auto-dismiss, and a boot that lands in the EFI shell gets rescued. The
# watchdog (scripts/watch-build.sh) polls the VNC framebuffer the plugin
# exposes (pinned to port 5901 in sandbox.pkr.hcl), OCRs each frame, and
# auto-dismisses the dialog/shell. Optional but recommended: without it,
# rebuilds can stall mid-installer. Skips with a warning when the deps are
# missing.

watchdog_pid=""
start_watchdog() {
  if ! python3 -c 'import vncdotool' 2>/dev/null; then
    echo "WARN: vncdotool not installed (pip3 install vncdotool) —" >&2
    echo "      the build may stall at installer screens without the watchdog." >&2
    return 1
  fi
  command -v swiftc >/dev/null 2>&1 || {
    echo "WARN: swiftc not found — the watchdog OCR helper needs the" >&2
    echo "      Xcode command line tools; skipping the watchdog." >&2
    return 1
  }
  mkdir -p "$cache_dir"

  # The watchdog types the grub autoinstall command itself (see
  # WATCH_BUILD_BOOT_CMD in scripts/watch-build.py): the firmware's
  # No-Media/PXE probe cycle before grub appears is variable-length, so
  # packer-side boot_command typing can fire before grub is up and the
  # menu's default entry would boot the interactive installer. The
  # watchdog waits for the grub menu/shell in the OCR, then types the
  # command. The ';' is escaped for grub with a backslash (an unquoted
  # ';' splits the command, and quoting via apostrophes proved unreliable
  # over the VNC keymap); the URL points at the vmnet8 host address,
  # where the seed server above listens.
  nat_subnet=$(sed -n 's/^subnet \([0-9.]*\) netmask.*/\1/p' \
    "/Library/Preferences/VMware Fusion/vmnet8/dhcpd.conf" 2>/dev/null | head -n1)
  if [ -z "$nat_subnet" ]; then
    echo "WARN: could not read the vmnet8 subnet from Fusion's DHCP config —" >&2
    echo "      the watchdog will not type the autoinstall command." >&2
  else
    nat_host="${nat_subnet%.*}.1"
    # Bash string (not printf): printf's escape handling would strip the
    # backslash before ';' (macOS printf drops unknown escapes).
    export WATCH_BUILD_BOOT_CMD="linux /casper/vmlinuz autoinstall ds=nocloud-net\\;s=http://$nat_host:$seed_port/ ---
initrd /casper/initrd
boot"
    rm -f "$cache_dir/watchdog/.boot-typed"
    echo "==> watchdog will type the autoinstall command for grub (seed at http://$nat_host:$seed_port/)"
  fi

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
  stop_seed_server
}
trap cleanup EXIT

# ---- packer pipeline ---------------------------------------------------------

start_seed_server

echo "==> packer init"
packer init "$platform_dir/sandbox.pkr.hcl"

echo "==> packer fmt -check"
packer fmt -check "$platform_dir" || {
  echo "WARN: 'packer fmt' would change formatting. Run 'packer fmt $platform_dir' to fix." >&2
}

echo "==> packer build"
start_watchdog || true
export PKR_VAR_iso_path="$UBUNTU_ISO_PATH"
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
# by older Fusion versions; see scripts/lib/vmware.sh).

if [ -n "$FUSION_APP_PATH" ]; then
  source "$repo_root/scripts/lib/vmware.sh"
  before=$(vmware_hw_version "$output") || before=""
  after=$(upgrade_vm_hardware "$output" "build output") || after=""
  if [ -n "$after" ] && [ -n "$before" ] && [ "$after" != "$before" ]; then
    echo "==> build output upgraded to hardware version $after"
  else
    echo "==> build output hardware version: ${after:-unknown}"
  fi
else
  echo "WARN: skipped the hardware upgrade (no Fusion at $FUSION_APP_PATH)." >&2
fi

echo "==> build output"
du -sh "$output_dir"
echo "Done: $output (export with ./scripts/deploy.sh $image_name)"
