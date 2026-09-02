// build-watchdog.ts — the VNC build watchdog the wrapper build flows
// share (scripts/watch-build.sh + scripts/watch-build.py): dependency
// checks (python3 + vncdotool, swiftc) with warn+skip, the OCR helper
// compiled if-stale into the watchdog dir, and a detached spawn of the
// bundled watch-build.py with a log file. The wrapper scripts'
// start_watchdog/stop_watchdog helpers land here.

import { existsSync, mkdirSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { commandExists, isExecutable, killTree, run, spawnDetached } from '../lib/exec.js';
import { logger } from '../lib/logger.js';

/** The VNC port the packer templates pin (vnc_port_min/max = 5901). */
const WATCHDOG_VNC_PORT = 5901;

/** The bundled watchdog files (assets/watchdog/*). */
export interface WatchdogAssets {
  /** The python supervisor/worker. */
  python: string;
  /** The Apple Vision OCR helper source (compiled to a binary). */
  ocrSwift: string;
}

/** The bundled watchdog asset root (dist/assets/watchdog); the compiled
 *  module sits at dist/lifecycle/, one level above the assets.
 *
 * @returns The watchdog assets dir.
 */
function watchdogAssetsRoot(): string {
  return fileURLToPath(new URL('../assets/watchdog', import.meta.url));
}

/** The watchdog asset paths.
 *
 * @param root - The assets root (defaults to the bundled dir).
 * @returns The python + swift paths.
 */
export function watchdogAssets(root: string = watchdogAssetsRoot()): WatchdogAssets {
  return { python: join(root, 'watch-build.py'), ocrSwift: join(root, 'watch-build-ocr.swift') };
}

/** @internal — test-only export of the compile-if-stale check (the
 *  shell's `[ ! -x $ocr ] || [ src -nt $ocr ]`).
 *
 * @param ocrPath - The compiled OCR binary.
 * @param srcPath - The swift source.
 * @returns True when a compile is due.
 */
export function ocrNeedsCompile(ocrPath: string, srcPath: string): boolean {
  if (!existsSync(ocrPath) || !isExecutable(ocrPath) || !existsSync(srcPath)) {
    return true;
  }
  return statSync(srcPath).mtimeMs > statSync(ocrPath).mtimeMs;
}

/** @internal — swiftc compile argv (test-only export).
 *
 * @param src - The swift source.
 * @param out - The output binary.
 * @returns The swiftc argv.
 */
export function swiftcArgs(src: string, out: string): string[] {
  return ['-O', src, '-o', out];
}

/** @internal — the watch-build.py argv (test-only export).
 *
 * @param port - The VNC port.
 * @param outdir - The frames dir.
 * @param ocr - The compiled OCR binary.
 * @param python - The watch-build.py path.
 * @returns The argv after python3.
 */
export function watchdogPyArgs(
  port: number,
  outdir: string,
  ocr: string,
  python: string,
): string[] {
  return [python, String(port), outdir, ocr];
}

/** Whether python3 + vncdotool are available.
 *
 * @returns True when the module imports.
 */
export async function pythonVncdotoolAvailable(): Promise<boolean> {
  const res = await run('python3', ['-c', 'import vncdotool']);
  return res.code === 0;
}

/** Warns and returns false when the watchdog deps are missing (the
 *  build continues without a watchdog).
 *
 * @returns True when vncdotool + swiftc are available.
 */
async function watchdogDepsAvailable(): Promise<boolean> {
  if (!(await pythonVncdotoolAvailable())) {
    logger.warn(
      'vncdotool not installed (pip3 install vncdotool) —\n' +
        '      the build may stall at build dialogs without the watchdog.',
    );
    return false;
  }
  if (!commandExists('swiftc')) {
    logger.warn(
      'swiftc not found — the watchdog OCR helper needs the\n' +
        '      Xcode command line tools; skipping the watchdog.',
    );
    return false;
  }
  return true;
}

/** Compiles the OCR helper when stale; returns its path.
 *
 * @param outdir - The watchdog frames dir (binary lands there).
 * @param assets - The watchdog assets.
 * @returns The OCR binary path, or undefined when the compile fails.
 */
export async function compileOcrHelper(
  outdir: string,
  assets: WatchdogAssets,
): Promise<string | undefined> {
  mkdirSync(outdir, { recursive: true });
  const ocr = join(outdir, 'watch-build-ocr');
  if (!ocrNeedsCompile(ocr, assets.ocrSwift)) {
    return ocr;
  }
  logger.step(`compiling the OCR helper (${ocr})`);
  const res = await run('swiftc', swiftcArgs(assets.ocrSwift, ocr));
  if (res.code !== 0) {
    logger.warn(`swiftc failed — skipping the watchdog (${res.stderr.trim()})`);
    return undefined;
  }
  return ocr;
}

/** The detached-build-watchdog options. */
export interface BuildWatchdogOptions {
  /** <build>/packer_cache — watchdog.log + frames live under it. */
  cacheDir: string;
  /** Extra env (WATCH_BUILD_BOOT_CMD for the Ubuntu flow). */
  env?: Record<string, string | undefined>;
  /** Assets override (tests). */
  assets?: WatchdogAssets;
}

/** Starts the detached watchdog (warn+skip when deps are missing).
 *
 * @param options - Cache dir / env / assets.
 * @returns The supervisor pid, or undefined when skipped.
 */
export async function startBuildWatchdog(
  options: BuildWatchdogOptions,
): Promise<number | undefined> {
  const assets = options.assets ?? watchdogAssets();
  if (!(await watchdogDepsAvailable())) {
    return undefined;
  }
  const outdir = join(options.cacheDir, 'watchdog');
  const ocr = await compileOcrHelper(outdir, assets);
  if (!ocr) {
    return undefined;
  }
  logger.step(`starting build watchdog (VNC port ${WATCHDOG_VNC_PORT}, frames in ${outdir})`);
  const pid = spawnDetached(
    'python3',
    watchdogPyArgs(WATCHDOG_VNC_PORT, outdir, ocr, assets.python),
    { logFile: join(options.cacheDir, 'watchdog.log'), env: options.env },
  );
  return pid > 0 ? pid : undefined;
}

/** Stops the watchdog: kill the supervisor tree, then the belt-and-braces
 *  pkill of any leftover `--worker` subprocesses holding the VNC port.
 *
 * @param pid - The supervisor pid (optional).
 */
export async function stopBuildWatchdog(pid?: number): Promise<void> {
  if (pid !== undefined && pid > 0) {
    await killTree(pid);
  }
  await run('pkill', ['-f', 'watch-build.py --worker']);
}

/** Removes the .boot-typed marker (the wrappers do this at watchdog
 *  start so the grub command is typed once per build).
 *
 * @param cacheDir - The build cache dir.
 */
export function clearBootTypedMarker(cacheDir: string): void {
  rmSync(join(cacheDir, 'watchdog', '.boot-typed'), { force: true });
}
