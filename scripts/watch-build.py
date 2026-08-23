#!/usr/bin/env python3
"""Watchdog for the headless Windows sandbox build.

Why it exists: the Packer build's boot_command types Enter 15 times to
answer the firmware's boot prompts. The stray keys can hit "Cancel" on
Windows Setup's "Installing Windows 11" screen — Setup then asks "Are you
sure you want to quit?" and, headless, nothing dismisses it: the build
stalls forever. Boot races can also land in the UEFI shell. This watchdog
polls the build's VNC framebuffer, OCRs each frame (Apple Vision via
scripts/watch-build-ocr.swift), and:

  - clicks "No" on the quit-confirmation dialog (at the OCR'd button
    position; falls back to measured coordinates for the 800x600 buffer),
  - presses a key when "Press any key to boot from CD or DVD" is on screen,
  - boots the ISO from the UEFI shell (fs0: + EFI\\BOOT\\BOOTAA64.EFI).

The supervisor runs every capture in a subprocess with a hard timeout, so a
hung VNC/OCR cycle cannot stall the watch. See scripts/watch-build.sh for
the entry point and prerequisites (python3 + vncdotool + swiftc).

Usage:
  watch-build.py <vnc-port> <outdir> <ocr-binary>
  watch-build.py --worker <vnc-port> <outdir> <ocr-binary> <frame>
"""

import os
import re
import subprocess
import sys
import time

# Fallback "No" button center for the 800x600 framebuffer (top-left origin),
# used when the OCR did not return a position for the button.
NO_BUTTON_FALLBACK = (487, 381)


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
        log('actions: ' + (','.join(actions) if actions else 'none'))
    finally:
        vnc.disconnect()


# --- supervisor: run the worker per frame with a hard timeout ---------------

def main():
    args = sys.argv[1:]
    if args and args[0] == '--worker':
        # Re-exec'd by the supervisor: one capture cycle.
        _, port, outdir, ocr, frame = args
        run_worker(port, outdir, ocr, frame)
        return

    port, outdir, ocr = args
    os.makedirs(outdir, exist_ok=True)
    log(f'watching VNC port {port} (frames in {outdir})')
    i = 0
    try:
        while True:
            frame = os.path.join(outdir, f'w{i:04d}.png')
            try:
                subprocess.run(
                    [sys.executable, os.path.abspath(__file__), '--worker',
                     port, outdir, ocr, frame],
                    timeout=90)
            except subprocess.TimeoutExpired:
                log('worker timed out — skipping this frame')
            except Exception as e:  # noqa: BLE001 - keep watching
                log(f'error: {e}')
            i += 1
            time.sleep(20)
    except KeyboardInterrupt:
        log('stopping')


if __name__ == '__main__':
    main()
