#!/bin/bash
#
# watch-build.sh — VNC watchdog for the headless Windows sandbox build.
#
# The Packer build is headless and unattended. Its boot_command types Enter
# 15 times in the first seconds to answer the firmware's boot prompts, and
# those stray keys can hit "Cancel" on Windows Setup's "Installing Windows
# 11" screen — Setup then asks "Are you sure you want to quit?" and nothing
# dismisses it, so the build stalls forever. Boot races can also land in the
# UEFI shell. This watchdog polls the build's VNC framebuffer, OCRs each
# frame (Apple Vision, see watch-build-ocr.swift), and:
#
#   1. clicks "No" on the quit-confirmation dialog (at the OCR'd button
#      position; falls back to measured coordinates for the 800x600
#      framebuffer),
#   2. presses a key when "Press any key to boot from CD or DVD" is on
#      screen (the boot_command's enters may have missed the prompt),
#   3. boots the Windows ISO from the UEFI shell
#      (fs0: + EFI\BOOT\BOOTAA64.EFI).
#
# The Python supervisor (watch-build.py) runs each capture in a subprocess
# with a hard timeout, so a hung VNC/OCR cycle cannot stall the watch.
#
# Usage:
#   scripts/watch-build.sh <vnc-port> [outdir]
#
# <outdir> defaults to images/windows-arm64-qemu/packer_cache/watchdog
# (gitignored build artifacts). Frames and the compiled OCR helper land
# there; the OCR helper is recompiled when its source is newer.
#
# Prerequisites:
#   - python3 with the vncdotool module:  pip3 install vncdotool
#   - Xcode command line tools (swiftc) — the OCR helper is compiled on
#     first use.
#
# images/windows-arm64-qemu/build.sh starts this script around `packer
# build`; the Packer template pins the VNC port (vnc_port_min/max), so the
# port argument is deterministic.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

port="${1:?usage: watch-build.sh <vnc-port> [outdir]}"
outdir="${2:-$repo_root/images/windows-arm64-qemu/packer_cache/watchdog}"

die() {
    printf '%s\n' "watch-build.sh: $*" >&2
    exit 1
}

python3 -c 'import vncdotool' 2>/dev/null ||
    die "the vncdotool module is missing — install it with: pip3 install vncdotool"
command -v swiftc >/dev/null 2>&1 ||
    die "swiftc is missing — install the Xcode command line tools."

mkdir -p "$outdir"
ocr="$outdir/watch-build-ocr"
if [ ! -x "$ocr" ] || [ "$repo_root/scripts/watch-build-ocr.swift" -nt "$ocr" ]; then
    echo "==> compiling the OCR helper ($ocr)"
    swiftc -O "$repo_root/scripts/watch-build-ocr.swift" -o "$ocr"
fi

echo "==> watching VNC port $port (frames: $outdir) — Ctrl+C to stop"
exec python3 "$repo_root/scripts/watch-build.py" "$port" "$outdir" "$ocr"
