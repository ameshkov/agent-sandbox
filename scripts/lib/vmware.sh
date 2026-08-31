#!/bin/bash
# scripts/lib/vmware.sh — shared helpers for the VMware sandboxes: vmrun
# resolution, the VM hardware-version upgrade, and the vmx displayName
# helper.
#
# Sourced by the platform build scripts (upgrade the built VM) and the
# sandbox runners (upgrade the working clone, poll the guest IP, ...).
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

# vmware_tools_state <vmx> — prints the VMware Tools state vmrun reports
# ("running", "notrunning", or an error line). The shared-folder
# registration (vmrun addSharedFolder) has to talk to the tools, and right
# after a guest boot/reboot they can still be starting while
# getGuestIPAddress and sshd already answer — the runners wait for
# "running" before registering the share. Same perl alarm wrapper as the
# getGuestIPAddress polls: vmrun can hang past its own timeouts.
vmware_tools_state() {
    perl -e 'alarm 30; exec @ARGV' "$vmrun_bin" -T fusion checkToolsState "$1" 2>/dev/null \
        | tail -n1
}

# set_vm_display_name <vmx> <name> — sets the VM's displayName (the name
# Fusion's VM library shows), replacing the existing displayname line or
# appending one when the vmx has none. `vmrun clone` inherits the source
# vmx's displayName, so the working clone would otherwise show up under the
# pristine image's name.
#
# vmx keys are case-insensitive: vmrun clone and Fusion write the key as
# lowercase `displayname` (the base vmx uses that spelling), while an
# earlier name may have been written as `displayName` — the first name the
# image built with, or a rename from an older run. Matching case-insensitively
# (and writing the canonical lowercase key) replaces the *first* key in
# either spelling and drops any follow-ups; a second, case-variant key in
# the same vmx would otherwise make Fusion refuse the VM with "Cannot read
# the virtual machine configuration file".
set_vm_display_name() {
    local vmx=$1 name=$2 tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/vmx-displayname.XXXXXX") || return 1
    awk -v name="$name" '
        tolower($0) ~ /^[[:space:]]*displayname[[:space:]]*=/ {
            print "displayname = \"" name "\""; seen = 1; next
        }
        { print }
        END { if (!seen) print "displayname = \"" name "\"" }
    ' "$vmx" >"$tmp" && mv "$tmp" "$vmx"
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
