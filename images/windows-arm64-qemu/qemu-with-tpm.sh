#!/bin/bash
# qemu-with-tpm.sh — wrapper around qemu-system-aarch64 that fills in the
# gaps Packer's qemu plugin can't generate for an ARM64 Windows build.
#
# Packer's qemu plugin treats `qemuargs` as a *replacement* for all
# auto-generated args, not an append — so instead of qemuargs, this script
# sits between Packer and qemu: Packer invokes it as if it were qemu, it
# forwards every arg verbatim (with surgical edits) and appends its
# additions at the end.
#
# What it adds / rewrites:
#
#   1. TPM 2.0 via the swtpm Unix socket (Windows 11 system requirement).
#   2. `ramfb` simple linear framebuffer. ARM `virt` machines ship no
#      graphics card by default; ramfb works because EFI firmware writes
#      to it directly (via GOP) — virtio-gpu needs guest drivers the
#      Windows installer doesn't have yet. (The build stages the ARM64
#      viogpudo driver onto the unattend CD anyway, so the *runtime*
#      runner can boot the built image with virtio-gpu-pci and the guest
#      driver store resolves it.)
#   3. USB controller + keyboard + tablet (no input devices otherwise;
#      usb-tablet gives absolute pointing).
#   4. virtio-win.iso attached as a CD-ROM via usb-storage, so the built
#      image can install virtio-win-guest-tools (full driver suite + qemu
#      guest agent). The boot-critical ARM64 driver subset WinPE needs at
#      install time is bundled into the unattend CD by build.sh, not this
#      CD.
#   5. Rewrite of Packer-generated CD-ROM drives to usb-storage. QEMU's
#      ARM `virt` machine has no IDE/SATA controller, and WinPE has no
#      in-box driver for the plugin's default CD attachment; it does
#      include the xHCI/USB stack, so usb-storage CDs are visible
#      immediately.
#
# USB enumeration order is load-bearing: EDK2 walks USB devices in argv
# order looking for `\EFI\Boot\bootaa64.efi`. The install ISO's
# usb-storage device MUST come before virtio-win.iso's, otherwise EDK2
# bails to the EFI Shell instead of booting Windows Setup.
#
# Required env (exported by images/windows-arm64-qemu/build.sh):
#   SWTPM_SOCK          — absolute path to the swtpm Unix socket
#   VIRTIO_WIN_ISO_PATH — absolute path to virtio-win.iso
#   QEMU_WITH_TPM_LOG   — log file for the final qemu invocation
#                         (build/windows-arm64-qemu/packer_cache/
#                         qemu-with-tpm.cmd.log)
#
# Adapted from bbirkinbine/mac-vms (MIT):
# https://github.com/bbirkinbine/mac-vms/blob/main/scripts/qemu-with-tpm.sh

set -euo pipefail

# Packer's qemu plugin probes the qemu binary with `-version` before it
# spawns the VM; answer it directly instead of erroring on the env checks
# below (SWTPM_SOCK/VIRTIO_WIN_ISO_PATH are only set for real VM runs).
if [[ "${1:-}" == "-version" || "${1:-}" == "--version" ]]; then
  exec qemu-system-aarch64 "$@"
fi

if [[ -z "${SWTPM_SOCK:-}" ]]; then
  echo "ERROR: SWTPM_SOCK not set; images/windows-arm64-qemu/build.sh must export it." >&2
  exit 1
fi

if [[ ! -S "${SWTPM_SOCK}" ]]; then
  echo "ERROR: SWTPM_SOCK=${SWTPM_SOCK} is not a Unix socket. Is swtpm running?" >&2
  exit 1
fi

if [[ -z "${VIRTIO_WIN_ISO_PATH:-}" ]]; then
  echo "ERROR: VIRTIO_WIN_ISO_PATH not set; images/windows-arm64-qemu/build.sh must export it." >&2
  exit 1
fi

if [[ ! -f "${VIRTIO_WIN_ISO_PATH}" ]]; then
  echo "ERROR: VIRTIO_WIN_ISO_PATH=${VIRTIO_WIN_ISO_PATH} does not exist." >&2
  exit 1
fi

# ---- rewrite Packer-generated CD-ROM drives to usb-storage ---------------
#
# Walk $@: for every `-drive` whose value contains `media=cdrom`, strip the
# `if=...` and `index=...` keys, append `if=none,id=cd<N>`, and emit a
# matching `-device usb-storage,drive=cd<N>` after all argument rewriting
# is done. Non-cdrom drives (notably `if=pflash` for EFI firmware/vars and
# `if=virtio` for the qcow2 system disk) pass through untouched.

rewritten_args=()
device_appends=()
cd_counter=0

args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[$i]}"
  if [[ "$arg" == "-drive" ]] && (( i + 1 < ${#args[@]} )); then
    val="${args[$((i + 1))]}"
    if [[ "$val" == *"media=cdrom"* ]]; then
      stripped="$(printf '%s' "$val" \
        | sed -E 's/(^|,)if=[^,]*//g; s/(^|,)index=[^,]*//g; s/^,+//; s/,,+/,/g; s/,$//')"
      cd_id="cd-pkr-${cd_counter}"
      cd_counter=$((cd_counter + 1))
      rewritten_args+=("-drive" "${stripped},if=none,id=${cd_id}")
      # bus=usb.0 explicit: the xhci controller defined in `extras` below
      # is the only USB bus on this VM, and unqualified `-device
      # usb-storage` can fail-fast on "no usb bus" because qemu resolves
      # device buses in argv order on ARM virt.
      device_appends+=("-device" "usb-storage,drive=${cd_id},bus=usb.0")
      i=$((i + 2))
      continue
    fi
  fi
  rewritten_args+=("$arg")
  i=$((i + 1))
done

# ---- our own appends ------------------------------------------------------
#
# Ordering is load-bearing for two independent reasons:
#
#   1. qemu-xhci MUST come before any usb-storage entries (both the
#      rewritten Packer cdroms in device_appends and our own virtio-win
#      attach below) — qemu's device-graph resolution can fail at parse
#      time if a usb-* device is seen before its bus exists.
#
#   2. The Packer install ISO's usb-storage device MUST enumerate before
#      virtio-win.iso's (see the header comment on USB enumeration
#      order).
#
# So the argv layout is split into two extras chunks:
#   - bus_extras (xhci + input + tpm + ramfb) — defines the USB bus
#   - virtio_win_storage (our virtio-win.iso usb-storage) — emitted LAST
# with device_appends (Packer's CDs as usb-storage) wedged between.

bus_extras=(
  -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}"
  -tpmdev "emulator,id=tpm0,chardev=chrtpm"
  # ppi=off: QEMU 11.1's HVF memory path aborts on the PPI region (a 1 KB,
  # non-page-aligned RAM device) with HV_BAD_ARGUMENT — hv_vm_unmap rejects
  # the unaligned size. Windows does not need PPI; disabling it dodges the
  # regression. See https://gitlab.com/qemu-project/qemu/-/issues for the
  # accel/hvf "Simplify hvf_set_phys_mem" fallout.
  -device "tpm-tis-device,tpmdev=tpm0,ppi=off"
  -device "ramfb"
  -device "qemu-xhci,id=usb"
  -device "usb-kbd,bus=usb.0"
  -device "usb-tablet,bus=usb.0"
)

virtio_win_storage=(
  -drive "file=${VIRTIO_WIN_ISO_PATH},media=cdrom,if=none,id=cd-virtio-win"
  -device "usb-storage,drive=cd-virtio-win,bus=usb.0"
)

final_argv=(
  "${rewritten_args[@]}"
  "${bus_extras[@]}"
  "${device_appends[@]}"
  "${virtio_win_storage[@]}"
)

# Log the final qemu invocation so future "Qemu failed to start" errors
# are debuggable without PACKER_LOG=1. build.sh exports the per-image log
# path; the fallback matches the old platform-dir layout for standalone
# runs.
qemu_log_file="${QEMU_WITH_TPM_LOG:-packer_cache/qemu-with-tpm.cmd.log}"
{
  echo "==> $(date -u +%FT%TZ) qemu-system-aarch64 invocation"
  printf '  %q\n' qemu-system-aarch64 "${final_argv[@]}"
} >"$qemu_log_file" 2>/dev/null || true

exec qemu-system-aarch64 "${final_argv[@]}"
