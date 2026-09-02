#!/usr/bin/env python3
"""Watchdog for the headless sandbox builds (Windows + Ubuntu).

Why it exists: the Packer build's boot_command types Enter 15 times to
answer the firmware's boot prompts. The stray keys can hit "Cancel" on
Windows Setup's "Installing Windows 11" screen — Setup then asks "Are you
sure you want to quit?" and, headless, nothing dismisses it: the build
stalls forever. Boot races can also land in the UEFI shell. This watchdog
polls the build's VNC framebuffer, OCRs each frame (Apple Vision via
watch-build-ocr.swift), and:

  - clicks "No" on the quit-confirmation dialog (at the OCR'd button
    position; falls back to measured coordinates for the 800x600 buffer),
  - presses a key when "Press any key to boot from CD or DVD" is on screen,
  - boots the ISO from the UEFI shell (fs0: + EFI\\BOOT\\BOOTAA64.EFI),
  - logs loudly when Windows Setup's "Windows could not complete the
    installation" dialog is on screen (the build then hangs at WinRM —
    nothing to click; the root cause is in the guest's Panther logs),
  - Ubuntu builds: types the autoinstall kernel command into grub when
    the grub menu or shell appears (WATCH_BUILD_BOOT_CMD env var, one
    grub command per line; the env var is read per frame, so it can be
    filled in after the build started, e.g. once the HTTP port is known).
    While the command is still untyped (no .boot-typed marker in the frame
    directory), the supervisor polls every 3 s — grub's menu countdown is
    ~20 s wide and the slow cadence (~2 min per frame) can miss it, which
    makes the interactive Subiquity installer boot instead of autoinstall
    and the build hang waiting for SSH. Once the command is typed (or the
    fast-poll cap passes), the slow cadence resumes. The grub command is
    typed only once per build (a marker file in the frame directory
    records it; the build wrapper removes the marker when the watchdog
    starts), and only after grub is actually on screen — the firmware's
    (variable-length) No-Media/PXE probe cycle no longer races the Packer
    boot_command typing.

The supervisor runs every capture in a subprocess with a hard timeout, so a
hung VNC/OCR cycle cannot stall the watch. See the CLI's `watch-build`
command for the entry point and prerequisites (python3 + vncdotool +
swiftc).

Usage:
  watch-build.py <vnc-port> <outdir> <ocr-binary>
  watch-build.py       --worker <vnc-port> <outdir> <ocr-binary> <frame>
"""

import os
import re
import subprocess
import sys
import time

# Fallback "No" button center for the 800x600 framebuffer (top-left origin),
# used when the OCR did not return a position for the button.
NO_BUTTON_FALLBACK = (487, 381)

# --- poll pacing -----------------------------------------------------------
#
# Until the Ubuntu autoinstall command is typed (or the hard cap below
# passes), the supervisor polls fast so at least one worker lands inside
# grub's ~20 s menu countdown. The slow cadence (90 s worker + 20 s sleep)
# scans a frame roughly every 2 minutes, so it can miss the menu entirely —
# the default entry then boots the interactive Subiquity installer and the
# build hangs waiting for SSH ("Timeout waiting for SSH" after the 60 m
# ssh_timeout; observed in the Ubuntu 24.04 build on 2026-08-29).
# Once .boot-typed exists the slow cadence resumes — the only screens left
# are the installer / Windows dialogs, which change on the minute timescale.
# The worker timeout stays at 90 s even in the fast phase: the worker's own
# OCR timeout (50 s) and connect timeout (10 s) bound a slow worker, and a
# kill mid-typing would corrupt the grub shell input line.
FAST_POLL_INTERVAL = 3
FAST_POLL_MAX_SECONDS = 240
SLOW_POLL_INTERVAL = 20
SLOW_POLL_WORKER_TIMEOUT = 90

# Ubuntu autoinstall boot command (rendered by the build wrapper; see the
# module docstring). Read per worker invocation, so the value can be
# provided after the watchdog started.
BOOT_CMD = os.environ.get('WATCH_BUILD_BOOT_CMD', '')


def log(msg):
    print(time.ctime(), msg, flush=True)


# --- worker: capture one frame, act on what is on screen --------------------

def type_colon(vnc):
    """The VNC keymap mangles ':' (shift modifier dropped), so send
    shift+';' explicitly."""
    vnc.keyDown('lshift')
    time.sleep(0.15)
    vnc.keyPress(';')
    time.sleep(0.15)
    vnc.keyUp('lshift')
    time.sleep(0.2)


def type_string(vnc, text):
    """Type a string character by character. ':' needs the shift trick
    (see type_colon); everything else is a plain key. Per-character
    try/except so an unmappable key never aborts the typing."""
    for ch in text:
        try:
            if ch == ':':
                type_colon(vnc)
            else:
                vnc.keyPress(ch)
                time.sleep(0.08)
        except Exception:  # noqa: BLE001 - keep typing the rest
            log(f'WARN: could not type {ch!r}')

    time.sleep(0.5)


def type_boot_command(vnc, outdir, at_shell):
    """Types the Ubuntu autoinstall grub command (BOOT_CMD, one grub
    command per line). 'c' opens the grub shell from the menu; when the
    shell prompt is already up (at_shell), the command lines are typed
    directly."""
    if not at_shell:
        vnc.keyPress('c')
        time.sleep(1.0)
    for line in BOOT_CMD.split('\n'):
        if not line.strip():
            continue
        type_string(vnc, line)
        vnc.keyPress('return')
        time.sleep(1.5)
    # Snapshot the shell right after typing (before/while the kernel
    # boots) — debugging aid: the frame shows the typed command line.
    try:
        vnc.captureScreen(os.path.join(outdir, 'boot-typed.png'))
    except Exception:  # noqa: BLE001 - best effort
        pass
    # The marker: typed once per build (the wrapper removes it when the
    # watchdog starts). The worker is re-exec-ed per frame, so state only
    # survives via this file.
    with open(os.path.join(outdir, '.boot-typed'), 'w') as f:
        f.write(time.ctime())


def click_no(vnc, position):
    vnc.mouseMove(*position)
    time.sleep(0.3)
    vnc.mousePress(1)
    time.sleep(0.2)
    vnc.mouseUp(1)
    time.sleep(0.5)


def shell_rescue(vnc):
    """Boot the Windows ISO from the UEFI shell."""
    for ch in 'fs0':
        vnc.keyPress(ch)
        time.sleep(0.25)
    type_colon(vnc)
    vnc.keyPress('return')
    time.sleep(2.5)
    for ch in r'EFI\BOOT\BOOTAA64.EFI':
        vnc.keyPress(ch)
        time.sleep(0.25)
    vnc.keyPress('return')
    time.sleep(1.5)
    vnc.keyPress('spacebar')
    time.sleep(0.5)
    vnc.keyPress('spacebar')


def find_no_button(ocr_text):
    """OCR lines look like 'No | center=(487,381) box=(...)' — return the
    center of the last line whose text is exactly 'No' (buttons sit at the
    bottom of the dialog), or None."""
    found = None
    for line in ocr_text.splitlines():
        if '|' not in line:
            continue
        label, _, rest = line.partition('|')
        if label.strip().lower() != 'no':
            continue
        m = re.search(r'center=\((\d+),(\d+)\)', rest)
        if m:
            found = (int(m.group(1)), int(m.group(2)))
    return found


def run_worker(port, outdir, ocr, frame):
    from vncdotool import api

    vnc = api.connect(f'127.0.0.1::{port}', timeout=10)
    try:
        vnc.captureScreen(frame)
        text = subprocess.run([ocr, frame], capture_output=True,
                              text=True, timeout=50).stdout
        actions = []
        if 'Are you sure you want to quit?' in text:
            actions.append('NO_CLICK')
            pos = find_no_button(text) or NO_BUTTON_FALLBACK
            click_no(vnc, pos)
        if 'Press any key to boot from CD' in text:
            actions.append('CD_KEY')
            vnc.keyPress('spacebar')
        if 'startup.nsh' in text or 'Shell>' in text or 'Shel1>' in text:
            actions.append('SHELL_RESCUE')
            shell_rescue(vnc)
        if 'could not complete the installation' in text:
            # Windows Setup (Win11, VMware Fusion): the first-boot pass
            # failed ("Windows could not complete the installation. To
            # install Windows on this computer, restart the
            # installation."). Clicking OK only restarts the broken
            # install — do not press anything; shout loudly instead, so
            # the build log shows the real state instead of Packer
            # spinning on "Waiting for WinRM" for 90 min. Diagnose from
            # C:\Windows\Panther\setuperr.log / setupact.log on the disk.
            actions.append('SETUP_FAILED')
            log('WINDOWS SETUP FAILED: "Windows could not complete the '
                'installation" dialog on screen — the build will hang at '
                'WinRM. Check C:\\Windows\\Panther\\setuperr.log.')
        if (BOOT_CMD and 'grub>' not in text
                and 'Try or Install Ubuntu Server' not in text):
            # keep silent: grub is not on screen yet
            pass
        elif BOOT_CMD and not os.path.exists(
                os.path.join(outdir, '.boot-typed')):
            # grub menu or shell is up: type the autoinstall command.
            actions.append('AUTOINSTALL_BOOT')
            type_boot_command(vnc, outdir, at_shell='grub>' in text)
        log('actions: ' + (','.join(actions) if actions else 'none'))
    finally:
        vnc.disconnect()


# --- supervisor: run the worker per frame with a hard timeout ---------------

def main():
    args = sys.argv[1:]
    if args and args[0] in ('-h', '--help'):
        print(__doc__)
        return
    if args and args[0] == '--worker':
        # Re-exec'd by the supervisor: one capture cycle.
        _, port, outdir, ocr, frame = args
        run_worker(port, outdir, ocr, frame)
        return

    port, outdir, ocr = args
    os.makedirs(outdir, exist_ok=True)
    log(f'watching VNC port {port} (frames in {outdir})')
    i = 0
    fast_until = time.time() + FAST_POLL_MAX_SECONDS
    try:
        while True:
            frame = os.path.join(outdir, f'w{i:04d}.png')
            # Fast-poll while the Ubuntu autoinstall command still has to be
            # typed (grub's menu countdown is only ~20 s wide); relax once
            # typed or when a boot never reaches grub (hard cap, so a stuck
            # interactive installer is watched at the gentle cadence).
            boot_marker = os.path.join(outdir, '.boot-typed')
            fast = bool(BOOT_CMD) and not os.path.exists(boot_marker) \
                and time.time() < fast_until
            try:
                subprocess.run(
                    [sys.executable, os.path.abspath(__file__), '--worker',
                     port, outdir, ocr, frame],
                    timeout=SLOW_POLL_WORKER_TIMEOUT)
            except subprocess.TimeoutExpired:
                log('worker timed out — skipping this frame')
            except Exception as e:  # noqa: BLE001 - keep watching
                log(f'error: {e}')
            i += 1
            time.sleep(FAST_POLL_INTERVAL if fast else SLOW_POLL_INTERVAL)
    except KeyboardInterrupt:
        log('stopping')


if __name__ == '__main__':
    main()
