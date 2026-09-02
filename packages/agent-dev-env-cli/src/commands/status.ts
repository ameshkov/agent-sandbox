// commands/status.ts — `agent-dev-env status [platform]`: live status of
// one or all platforms. New command (no shell equivalent): reports whether
// the default image is pulled, whether the working VM exists, and whether
// it is running, per platform. Read-only and informational: missing
// tooling is reported, not fatal.

import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { defaultImageFor, imageVersion, type CatalogImage } from '../lifecycle/catalog.js';
import { isAlive, readPidFile, run } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { qemuImagePath, qemuPidFile, qemuStateDir, qemuWorkingDir } from '../lib/qemu.js';
import { imageRootDir } from '../lib/paths.js';
import { PLATFORM_DEFAULTS, PLATFORMS, type Platform } from '../lib/platform.js';
import { listVms, tartAvailable, vmIp } from '../lib/tart.js';
import { findVmrun, listRunningVms } from '../lib/vmrun.js';

/** Prints the live status of one platform (or all platforms when none is
 *  given).
 *
 * @param platformArg - The platform to report on; all when omitted.
 * @returns Exit code: always 0 (status is informational).
 */
export async function statusCmd(platformArg?: Platform): Promise<number> {
  const targets: Platform[] = platformArg ? [platformArg] : [...PLATFORMS];
  for (const [i, platform] of targets.entries()) {
    if (i > 0) {
      logger.out('');
    }
    await printStatus(platform);
  }
  return 0;
}

/** Prints one platform's status. */
async function printStatus(platform: Platform): Promise<void> {
  logger.title(platform);

  let image: CatalogImage;
  try {
    image = defaultImageFor(platform);
  } catch (err) {
    logger.warn((err as Error).message);
    return;
  }

  let version = '?';
  try {
    version = imageVersion(image);
  } catch {
    // vars file without image_version — show '?' and let deploy/tag fail.
  }

  const defs = PLATFORM_DEFAULTS[platform];
  const details: string[] = [`image: ${image.name} (v${version})`];

  switch (platform) {
    case 'macos':
      await readMacosStatus(image.name, defs.vmName, details);
      break;
    case 'windows-qemu':
      await readQemuStatus(image, details);
      break;
    case 'windows-vmware':
    case 'ubuntu-vmware':
      await readVmwareStatus(platform, image, details);
      break;
  }

  for (const line of details) {
    logger.info(line);
  }
}

async function readMacosStatus(
  imageName: string,
  vmName: string,
  details: string[],
): Promise<void> {
  if (!tartAvailable()) {
    details.push('tart: not installed (brew install cirruslabs/cli/tart)');
    return;
  }
  const vms = await listVms();

  const imageState = vms.get(imageName);
  details.push(imageState ? `image: pulled (${imageState})` : 'image: not pulled');

  const vmState = vms.get(vmName);
  if (!vmState) {
    details.push(`VM: ${vmName} — not created`);
    return;
  }
  if (vmState === 'running') {
    const ip = await vmIp(vmName);
    details.push(`VM: ${vmName} — running${ip ? ` (${ip})` : ''}`);
  } else {
    details.push(`VM: ${vmName} — ${vmState}`);
  }
}

async function readQemuStatus(image: CatalogImage, details: string[]): Promise<void> {
  const stateDir = qemuStateDir(image.name);
  const workingDir = qemuWorkingDir(image.name);
  const pidFile = qemuPidFile(image.name);

  details.push(existsSync(qemuImagePath(image.name)) ? 'image: pulled' : 'image: not pulled');

  let running = false;
  let pid: number | undefined;
  pid = readPidFile(pidFile);
  if (pid !== undefined) {
    running = isAlive(pid);
  } else if (existsSync(stateDir)) {
    // A VM started without a pidfile (or a stale one): the overlay path is
    // unique to this sandbox — same fallback as the stop script.
    const pgrep = await run('pgrep', ['-f', `qemu-system-aarch64.*${stateDir}`]);
    running = pgrep.code === 0 && pgrep.stdout.trim() !== '';
  }

  if (!existsSync(workingDir)) {
    details.push(`VM: ${image.name} — not created (no state at ${stateDir})`);
  } else {
    details.push(running ? `VM: ${image.name} — running (qemu pid ${pid ?? '?'})` : 'VM: stopped');
  }
}

async function readVmwareStatus(
  platform: Platform,
  image: CatalogImage,
  details: string[],
): Promise<void> {
  const stateDir = imageRootDir(platform, image.name);
  const archive = join(stateDir, 'image', `${image.name}.tar.gz`);
  const baseDir = join(stateDir, 'base');
  const workingVmx = join(stateDir, 'working', `${image.name}.vmx`);

  details.push(existsSync(archive) || existsSync(baseDir) ? 'image: pulled' : 'image: not pulled');

  if (!existsSync(workingVmx)) {
    details.push(`VM: ${image.name} — not created (no state at ${stateDir})`);
    return;
  }

  const vmrun = findVmrun();
  if (!vmrun) {
    details.push('VM: state unknown — vmrun not found (VMware Fusion missing?)');
    return;
  }
  let running = false;
  try {
    const runningVms = await listRunningVms({ vmrun });
    const wanted = normalizePath(workingVmx);
    running = runningVms.some((p) => normalizePath(p) === wanted);
  } catch (err) {
    details.push(`vmrun list failed: ${(err as Error).message}`);
    return;
  }
  details.push(running ? `VM: ${image.name} — running` : 'VM: stopped');
}

function normalizePath(p: string): string {
  return p.replace(/\/+/g, '/');
}
