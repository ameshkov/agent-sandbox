#!/bin/bash
# scripts/lib/windows-vmware/lib.sh — shared helpers for the Windows VMware
# sandbox: vmrun resolution and the post-build VM hardware-version upgrade.
#
# Sourced by images/windows-arm64-vmware/build.sh (upgrade the built VM) and
# scripts/run-windows-vmware-sandbox.sh (upgrade the working clone).
#
# Why the upgrade exists: the vmware-iso builder writes the VM at hardware
# version 20 (the "hardware version" the template pins), and a newer Fusion
# version supports a higher one. Fusion does not complain on a headless
# vmrun start, but the first GUI (Fusion window) start of such a VM shows a
# one-time "Upgrade this virtual machine?" prompt that blocks the boot until
# someone clicks it. `vmrun upgradevm` upgrades the vmx/vmdk to the level
# the installed Fusion would write for a new VM, killing the prompt — run
# once per artifact (build.sh) and once per working clone (the runner).
#
# Note: vmrun upgradevm never exits. It prints "ServiceImpl_Opener: PID ..."
# and blocks after doing the work (even when the VM is already at the newest
# version), so it is run under the perl alarm wrapper and the callers check
# virtualhw.version in the vmx afterwards.

# vmrun_bin: resolve once (PATH first, then the Fusion app bundle).
if [ -z "${vmrun_bin:-}" ]; then
    if command -v vmrun >/dev/null 2>&1; then
        vmrun_bin=$(command -v vmrun)
    else
        fusion_app="${FUSION_APP_PATH:-/Applications/VMware Fusion.app}"
        if [ -x "$fusion_app/Contents/Public/vmrun" ]; then
            vmrun_bin="$fusion_app/Contents/Public/vmrun"
        fi
    fi
fi

# vmrun <args> — runs vmrun with the Fusion host type.
vmrun() {
    PATH="/Applications/VMware Fusion.app/Contents/Public:${PATH}" "$vmrun_bin" -T fusion "$@"
}

# vmware_hw_version <vmx> — prints the VM's virtualhw.version ("20", "22").
vmware_hw_version() {
    sed -n 's/^[[:space:]]*virtualhw\.version[[:space:]]*=[[:space:]]*"\([0-9]*\)"[[:space:]]*$/\1/p' "$1" \
        | head -n1
}

# upgrade_vm_hardware <vmx> [label] — upgrades the VM to the hardware version
# the installed Fusion supports (the version Fusion writes for a new VM; the
# image is built at 20).
#
# stdout: the resulting virtualhw.version (the original value when nothing
# moved, i.e. the VM was already at the newest version). Returns 0 when the
# upgrade ran (or was a no-op), 1 when vmrun cannot be found.
upgrade_vm_hardware() {
    local vmx=$1 label=${2:-VM}
    local before after
    before=$(vmware_hw_version "$vmx") || before=""

    if [ -z "$vmrun_bin" ] || [ ! -x "$vmrun_bin" ]; then
        echo "WARN: vmrun not found — cannot upgrade $label to the current" >&2
        echo "      Fusion hardware version; a GUI start may prompt once." >&2
        return 1
    fi

    # Up to 180 s: the upgrade rewrites the vmx and the vmdk descriptor
    # (~15 s measured on a ~27 GB sparse disk); the vmrun client itself
    # then hangs until the alarm fires.
    echo "==> upgrading $label (hardware version ${before:-unknown}) with vmrun upgradevm" >&2
    # The alarm fires at 180 s no matter what — see the header note about
    # upgradevm never exiting on its own. A killed client still leaves the
    # upgrade finished (the vmx is written before vmrun blocks).
    perl -e 'alarm 180; exec @ARGV' "$vmrun_bin" -T fusion upgradevm "$vmx" >/dev/null 2>&1 || true

    after=$(vmware_hw_version "$vmx") || after=""
    if [ -z "$after" ]; then
        echo "WARN: could not read virtualhw.version after the upgrade." >&2
        return 1
    fi
    printf '%s\n' "$after"
    return 0
}
