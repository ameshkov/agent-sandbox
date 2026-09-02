// runners/vmware-image.ts — step 1 for the VMware backends (ubuntu-vmware
// and windows-vmware, Phase 4 + Phase 5): pick the image archive (env
// override → local build output → cached pull → oras pull), extract the
// pristine base (identity marker = path|size|mtime, so a rebuild over the
// same path is detected), clone the working VM + set its display name,
// and upgrade it once per hardware version (.hw-version). Port of
// run-{ubuntu,windows}-vmware-sandbox.sh §step 1/2; the CLI's data dir
// replaces the legacy agent-sandbox one. The per-platform pieces (platform
// id, the archive override env var) are parameters, so the two VMware
// backends share one implementation.
//
// The thin per-platform wrappers (ubuntu-image.ts / windows-image.ts)
// bind the platform id + override var; everything else is here.

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { commandExists, run } from '../lib/exec.js';
import { registryRef, resolveOwner } from '../lib/ghcr.js';
import { logger } from '../lib/logger.js';
import { buildDir, imageRootDir, vmwareArchivePath, workingVmxPath } from '../lib/paths.js';
import type { Platform } from '../lib/platform.js';
import { confirmDefault } from '../lib/prompt.js';
import { cloneVm, setVmDisplayName, upgradeVmHardware, vmwareHwVersion } from '../lib/vmrun.js';
import type { RunContext, RunState } from './framework.js';

/** @internal — the pristine-archive identity (path|size|mtime; the same
 *  scheme as the QEMU runner's backing-image marker — a rebuild packs the
 *  new image at the SAME path, so the path alone misses it).
 *
 * @param path - The archive path.
 * @param size - File size in bytes.
 * @param mtimeMs - File mtime (ms since epoch).
 * @returns The identity string.
 */
export function archiveIdentity(path: string, size: number, mtimeMs: number): string {
  return `${path}|${size}|${Math.floor(mtimeMs / 1000)}`;
}

/** The base directory of the pristine extraction. */
function baseDir(platform: Platform, image: string): string {
  return join(imageRootDir(platform, image), 'base');
}

/** The pristine base vmx. */
function baseVmx(platform: Platform, image: string): string {
  return join(baseDir(platform, image), `${image}.vmx`);
}

/** The archive identity marker path. */
function baseMarker(platform: Platform, image: string): string {
  return join(imageRootDir(platform, image), 'base-archive.txt');
}

/** The working clone's vmx. */
export function vmwareWorkingVmx(platform: Platform, image: string): string {
  return workingVmxPath(platform, image);
}

/** The .hw-version marker (records the upgraded hardware version). */
function hwMarker(platform: Platform, image: string): string {
  return join(dirname(vmwareWorkingVmx(platform, image)), '.hw-version');
}

/** Step 1: select the archive, extract the base, clone the working VM
 *  and upgrade it if the installed Fusion supports a newer hardware
 *  version.
 *
 * @param platform - The target platform (state dir naming).
 * @param overrideEnv - The env var holding a local archive override
 *   (UBUNTU_VMWARE_IMAGE / WINDOWS_VMWARE_IMAGE).
 * @param context - The run context.
 * @param state - The accumulated run state (imageArchive set here).
 */
export async function ensureVmwareImage(
  platform: Platform,
  overrideEnv: string,
  context: RunContext,
  state: RunState,
): Promise<void> {
  const archive = await pickImage(platform, overrideEnv, context);
  state.imageArchive = archive;
  logger.ok(`Using archive: ${archive}`);
  await ensureBase(platform, context, archive);
  if (!(await ensureWorkingVm(platform, context))) {
    logger.die(
      'could not clone the working VM (see above). Check Fusion\u2019s VM library path and re-run.',
    );
  }
  await upgradeWorkingVm(platform, context);
}

/** The shell's pick_image: <OVERRIDE_ENV> → local build output (packed on
 *  demand) → cached pull → oras pull with the owner chain.
 *
 * @param platform - The target platform.
 * @param overrideEnv - The environment override variable name.
 * @param context - The run context.
 * @returns The archive path to run.
 */
async function pickImage(
  platform: Platform,
  overrideEnv: string,
  context: RunContext,
): Promise<string> {
  const env = context.options.env;
  const image = context.image;
  const override = env[overrideEnv];
  if (override) {
    if (!existsSync(override)) {
      logger.die(`${overrideEnv} points to a file that does not exist: ${override}`);
    }
    return override;
  }
  const outputDir = join(buildDir(platform), 'output');
  const local = join(outputDir, `${image}.tar.gz`);
  if (existsSync(join(outputDir, `${image}.vmx`)) && !existsSync(local)) {
    logger.info(`No archive yet — packing the local build output into ${local}`);
    const vmdks = readdirSync(outputDir)
      .filter((file) => file.endsWith('.vmdk'))
      .map((file) => join(outputDir, file));
    mkdirSync(dirname(local), { recursive: true });
    const packed = await run(
      'tar',
      ['-czf', local, '--exclude=*.log', `${image}.vmx`, `${image}.nvram`, ...vmdks],
      { cwd: outputDir },
    );
    if (packed.code !== 0) {
      logger.die(`failed to pack the local build output:\n${packed.stderr.trim()}`);
    }
  }
  if (existsSync(local)) {
    return local;
  }

  const cached = vmwareArchivePath(platform, image);
  if (existsSync(cached)) {
    return cached;
  }
  return pullImage(platform, overrideEnv, context, cached);
}

/** The oras pull into the image/ cache dir (owner chain + confirm +
 *  archive presence check).
 *
 * @param platform - The target platform.
 * @param overrideEnv - The environment override variable name (prompts).
 * @param context - The run context.
 * @param cached - The destination archive path.
 * @returns The pulled archive path.
 */
async function pullImage(
  platform: Platform,
  overrideEnv: string,
  context: RunContext,
  cached: string,
): Promise<string> {
  if (!commandExists('oras')) {
    logger.die(
      'oras is not installed — needed to pull the image (brew install oras). ' +
        `Set ${overrideEnv} to a local archive to skip.`,
    );
  }
  const owner = await resolveOwner({ owner: context.options.owner, env: context.options.env });
  const ref = registryRef(context.image, 'latest', owner);
  const hint = platform === 'windows-vmware' ? '~20 GB' : '~15 GB';
  if (
    !(await confirmDefault(`Pull ${ref} (one-time, ${hint} download)?`, {
      default: 'y',
      yes: context.options.yes,
    }))
  ) {
    logger.die(
      `aborted — no sandbox image available. Set ${overrideEnv} to a local archive or pull manually.`,
    );
  }
  mkdirSync(dirname(cached), { recursive: true });
  logger.info(`Pulling ${ref} (one-time, ${hint} download)...`);
  const res = await run('oras', ['pull', ref], { cwd: dirname(cached) });
  if (res.code !== 0) {
    logger.die(
      'oras pull failed — check your network connection (public GHCR images pull without a login).',
    );
  }
  if (!existsSync(cached)) {
    logger.die(`oras pull produced no ${cached} — is the image published under ${ref}?`);
  }
  return cached;
}

/** Extracts the pristine archive into base/ (identity-marker gated; an
 *  archive change drops base + the working clone).
 *
 * @param platform - The target platform.
 * @param context - The run context.
 * @param archive - The archive to extract.
 */
async function ensureBase(platform: Platform, context: RunContext, archive: string): Promise<void> {
  const image = context.image;
  const markerPath = baseMarker(platform, image);
  const baseDirPath = baseDir(platform, image);
  const baseVmxPath = baseVmx(platform, image);
  const stat = statSync(archive);
  const id = archiveIdentity(archive, stat.size, stat.mtimeMs);

  const hadMarker = existsSync(markerPath);
  const marker = hadMarker ? readFileSync(markerPath, 'utf8').trim() : '';
  if (hadMarker && marker !== id) {
    logger.warn(
      'The archive changed (new build or pull) — re-extracting the pristine VM and dropping the working clone.',
    );
    logger.warn(
      'The working clone\u2019s guest state (installs, config, agent files) is lost with it.',
    );
    rmSync(baseDirPath, { recursive: true, force: true });
    rmSync(join(imageRootDir(platform, image), 'working'), { recursive: true, force: true });
  }
  if (marker === id && existsSync(baseVmxPath)) {
    logger.ok(`Pristine VM extracted (${baseDirPath}).`);
    return;
  }
  mkdirSync(baseDirPath, { recursive: true });
  logger.cmd(`tar -xzf ${archive} -C ${baseDirPath}`);
  const res = await run('tar', ['-xzf', archive, '-C', baseDirPath]);
  if (res.code !== 0) {
    logger.die(`archive extraction failed:\n${res.stderr.trim()}`);
  }
  writeFileSync(markerPath, id);
  if (!existsSync(baseVmxPath)) {
    logger.die(`archive extraction produced no ${baseVmxPath} (is the archive valid?)`);
  }
  logger.ok(`Pristine VM extracted (${baseVmxPath}).`);
}

/** Clones the pristine base into the working VM + sets the display name
 *  (clone inherits the base's — the working VM would show under the
 *  base's name in Fusion's library otherwise).
 *
 * @param platform - The target platform.
 * @param context - The run context.
 * @returns True when the clone exists.
 */
async function ensureWorkingVm(platform: Platform, context: RunContext): Promise<boolean> {
  const image = context.image;
  const wVmx = vmwareWorkingVmx(platform, image);
  if (existsSync(wVmx)) {
    logger.ok(`Working VM exists (${wVmx}).`);
    return true;
  }
  mkdirSync(dirname(wVmx), { recursive: true });
  logger.cmd(`vmrun -T fusion clone ${baseVmx(platform, image)} ${wVmx} full`);
  const res = await cloneVm(baseVmx(platform, image), wVmx);
  if (res.code !== 0) {
    logger.warn('full clone failed (Fusion may have rejected the destination path).');
    return false;
  }
  logger.cmd(`set displayName "${context.vm}" in ${wVmx}`);
  if (!setVmDisplayName(wVmx, context.vm)) {
    logger.warn(
      'could not set the working VM\u2019s display name (Fusion will show the base\u2019s name).',
    );
  }
  logger.ok(`Working VM cloned (${wVmx}; display name '${context.vm}').`);
  return true;
}

/** Upgrades the working clone once per hardware version (vmrun
 *  upgradevm — the no-op hang is why it runs only when the marker
 *  differs).
 *
 * @param platform - The target platform.
 * @param context - The run context.
 */
async function upgradeWorkingVm(platform: Platform, context: RunContext): Promise<void> {
  const wVmx = vmwareWorkingVmx(platform, context.image);
  const before = vmwareHwVersion(wVmx);
  if (!before) {
    return;
  }
  const markerPath = hwMarker(platform, context.image);
  const marker = existsSync(markerPath) ? readFileSync(markerPath, 'utf8').trim() : '';
  if (marker === before) {
    return;
  }
  const after = await upgradeVmHardware(wVmx);
  if (!after) {
    logger.warn(
      'could not upgrade the working VM (vmrun missing?) — the first GUI start may prompt.',
    );
    return;
  }
  writeFileSync(markerPath, after);
  if (after !== before) {
    logger.ok(
      `Working VM upgraded to hardware version ${after} (the installed Fusion\u2019s current).`,
    );
  }
}
