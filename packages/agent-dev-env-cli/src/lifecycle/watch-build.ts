// watch-build.ts — the hidden `watch-build` command: the port of
// scripts/watch-build.sh. Checks python3 + vncdotool and swiftc (hard
// errors — this is the manual watchdog invocation, not a build wrapper),
// compiles the OCR helper if-stale, then runs the bundled watch-build.py
// in the foreground (Ctrl+C stops it, same as the shell's `exec`).

import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { commandExists } from '../lib/exec.js';
import { buildDir } from '../lib/paths.js';
import { logger } from '../lib/logger.js';
import { compileOcrHelper, pythonVncdotoolAvailable, watchdogAssets } from './build-watchdog.js';

/** The watch-build command options. */
export interface WatchBuildOptions {
  /** Reserved (a future OCR-less mode); accepted but not implemented. */
  noOcr?: boolean;
}

/** The default frames dir (<data>/build/windows-qemu/packer_cache/
 *  watchdog).
 *
 * @returns The default outdir.
 */
function defaultWatchdogOutdir(): string {
  return join(buildDir('windows-qemu'), 'packer_cache', 'watchdog');
}

/** `agent-dev-env watch-build <vnc-port> [outdir]` (hidden).
 *
 * @param vncPort - The VNC port of the packer build.
 * @param outdir - The frames dir (defaults per platform state layout).
 * @param options - The command options (--no-ocr reserved).
 * @returns The python supervisor's exit code.
 */
export async function watchBuildCmd(
  vncPort: number,
  outdir?: string,
  options: WatchBuildOptions = {},
): Promise<number> {
  void options.noOcr;
  if (!(await pythonVncdotoolAvailable())) {
    logger.die('the vncdotool module is missing — install it with: pip3 install vncdotool');
  }
  if (!commandExists('swiftc')) {
    logger.die('swiftc is missing — install the Xcode command line tools.');
  }
  const assets = watchdogAssets();
  const dir = outdir ?? defaultWatchdogOutdir();
  mkdirSync(dir, { recursive: true });
  const ocr = await compileOcrHelper(dir, assets);
  if (!ocr) {
    logger.warn('swiftc failed — the OCR helper is required for the watchdog.');
    return 1;
  }
  logger.step(`watching VNC port ${vncPort} (frames: ${dir}) — Ctrl+C to stop`);
  return runForeground('python3', [assets.python, String(vncPort), dir, ocr]);
}

/** Runs a process with inherited stdio and resolves with its exit code
 *  (the shell's `exec`-style foreground run).
 *
 * @param cmd - The command.
 * @param args - The argv.
 * @returns The exit code.
 */
function runForeground(cmd: string, args: string[]): Promise<number> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: 'inherit' });
    child.on('error', () => {
      resolve(1);
    });
    child.on('close', (code) => {
      resolve(code ?? 1);
    });
  });
}
