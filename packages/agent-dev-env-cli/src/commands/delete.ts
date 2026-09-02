// commands/delete.ts — `agent-dev-env delete <platform> [--yes]
// [--pristine]`: stop the sandbox (delegating to the same flow as
// `stop`), then remove the VM/state. macOS: `tart delete` the working VM
// (+ the pristine image with --pristine). VMware (Ubuntu + Windows) and
// QEMU (Windows): `rm -rf` the state dir (extracted base + working clone
// or overlay/TPM/NVRAM + pulled cache) — the next run re-pulls and
// re-clones.

import { existsSync, rmSync } from 'node:fs';
import { run } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { imageRootDir } from '../lib/paths.js';
import type { Platform } from '../lib/platform.js';
import { qemuStateDir } from '../lib/qemu.js';
import { deleteVm, stopVm, tartAvailable, vmExists, vmState } from '../lib/tart.js';
import { findVmrun } from '../lib/vmrun.js';
import { confirm } from '../lib/prompt.js';
import { resolveRunOptions } from '../runners/options.js';
import { stopMacos, stopQemuSandbox, stopVmware } from './stop.js';

export interface DeleteOptions {
  yes?: boolean;
  pristine?: boolean;
}

/** Deletes a sandbox platform.
 *
 * @param platform - The platform to delete.
 * @param options - --yes / --pristine flags.
 * @returns The process exit code.
 */
export async function deleteCmd(platform: Platform, options: DeleteOptions): Promise<number> {
  if (platform === 'macos') {
    await deleteMacos(options);
    return 0;
  }
  if (platform === 'windows-qemu') {
    await deleteQemu(options);
    return 0;
  }
  await deleteVmware(platform, options);
  return 0;
}

/** The macOS delete flow (working VM, optionally the pristine image). */
async function deleteMacos(options: DeleteOptions): Promise<void> {
  if (!tartAvailable()) {
    logger.die("tart is not installed — run 'brew install cirruslabs/cli/tart' first.");
  }
  const runOptions = resolveRunOptions('macos', { yes: options.yes });
  const { vm, image } = runOptions;
  const yes = options.yes === true;

  logger.title(`Deleting macOS sandbox: ${vm}`);

  logger.step('Stopping the sandbox');
  await stopMacos();

  logger.step('Deleting the working VM');
  if (await vmExists(vm)) {
    const ask =
      `Delete the working VM '${vm}'? This stops and removes it — the next ` +
      `run re-clones it from '${image}'.`;
    if (yes || (await confirm(ask, { default: 'y' }))) {
      logger.cmd(`tart delete ${vm}`);
      const res = await deleteVm(vm);
      if (res.code === 0) {
        if (await vmExists(vm)) {
          logger.warn(`VM '${vm}' still exists after 'tart delete'.`);
        }
        logger.ok(`Working VM '${vm}' deleted.`);
      } else {
        logger.warn(`'tart delete ${vm}' failed — is it running?`);
      }
    } else {
      logger.info(`Kept '${vm}' — nothing was deleted.`);
    }
  } else {
    logger.info(`Working VM '${vm}' does not exist (already deleted?) — nothing to delete.`);
  }

  await maybeDeletePristine(image, yes, options.pristine === true);

  logger.step('Sandbox deleted');
  logger.info(`Working VM: ${vm} — deleted if it existed (next run re-clones from '${image}').`);
  logger.info('Pristine image: ' + image + ' — kept or deleted per the flags above.');
  logger.info('Next run: agent-dev-env run macos');
}

/** The VMware delete flow — stop first, then remove the state dir
 *  (shared by the Ubuntu and Windows backends).
 *
 * @param platform - The VMware platform to delete.
 * @param options - --yes flag.
 */
async function deleteVmware(platform: Platform, options: DeleteOptions): Promise<void> {
  if (!findVmrun()) {
    logger.die(
      'vmrun not found — install VMware Fusion (free for personal use) or set FUSION_APP_PATH.',
    );
  }
  const runOptions = resolveRunOptions(platform, { yes: options.yes });
  const stateDir = imageRootDir(platform, runOptions.image);
  const yes = options.yes === true;
  const label = platform === 'ubuntu-vmware' ? 'Ubuntu' : 'Windows';

  logger.title(`Deleting ${label} VMware sandbox: ${runOptions.image}`);

  logger.step('Stopping the sandbox');
  await stopVmware(platform);

  logger.step('Deleting the state');
  if (!existsSync(stateDir)) {
    logger.info(`No state at ${stateDir} (already deleted?) — nothing to delete.`);
  } else {
    const size = await dirSizeHuman(stateDir);
    const ask =
      `Delete the sandbox state at '${stateDir}' (${size}; re-pulled on the next run)? ` +
      `This removes the pristine base and the working clone of '${runOptions.image}'.`;
    if (yes || (await confirm(ask, { default: 'y' }))) {
      logger.cmd(`rm -rf ${stateDir}`);
      rmSync(stateDir, { recursive: true, force: true });
      logger.ok(`State deleted: ${stateDir} (${size} freed).`);
      logger.warn(
        "Fusion's VM library may still list the deleted working VM — remove the stale entry in the Fusion UI (harmless).",
      );
    } else {
      logger.info(`Kept '${stateDir}' — nothing was deleted.`);
    }
  }

  logger.step('Sandbox deleted');
  logger.info(`State: ${stateDir}`);
  logger.info(`Next run: agent-dev-env run ${platform} (re-pulls the archive)`);
}

/** The QEMU delete flow — stop first (delegating to the stop flow), then
 *  remove the state dir (working disk overlay + TPM + EFI NVRAM + the
 *  pulled image cache). The next run re-pulls the image and starts fresh.
 *
 * @param options - --yes flag.
 */
async function deleteQemu(options: DeleteOptions): Promise<void> {
  const runOptions = resolveRunOptions('windows-qemu', { yes: options.yes });
  const stateDir = qemuStateDir(runOptions.image);
  const yes = options.yes === true;

  logger.title(`Deleting Windows QEMU sandbox: ${runOptions.image}`);

  logger.step('Stopping the sandbox');
  await stopQemuSandbox();

  logger.step('Deleting the state');
  if (!existsSync(stateDir)) {
    logger.info(`No state at ${stateDir} (already deleted?) — nothing to delete.`);
  } else {
    const size = await dirSizeHuman(stateDir);
    const ask =
      `Delete the sandbox state at '${stateDir}' (${size}; re-pulled on the next run)? ` +
      `This removes the working overlay + TPM + EFI NVRAM and the pulled image of '${runOptions.image}'.`;
    if (yes || (await confirm(ask, { default: 'y' }))) {
      logger.cmd(`rm -rf ${stateDir}`);
      rmSync(stateDir, { recursive: true, force: true });
      logger.ok(`State deleted: ${stateDir} (${size} freed).`);
    } else {
      logger.info(`Kept '${stateDir}' — nothing was deleted.`);
    }
  }

  logger.step('Sandbox deleted');
  logger.info(`State: ${stateDir}`);
  logger.info(`Next run: agent-dev-env run windows-qemu (re-pulls the image)`);
}

/** @internal — `du -sh`-style human size ("12G", "812M"); '?' on failure. */
export async function dirSizeHuman(dir: string): Promise<string> {
  const res = await run('du', ['-sh', dir]);
  return res.code === 0 ? res.stdout.trim().split('\t')[0] : '?';
}

/** The pristine-image deletion — always opt-in (never implied). */
async function maybeDeletePristine(image: string, yes: boolean, pristine: boolean): Promise<void> {
  const ask =
    `Also delete the pristine image '${image}' (frees ~50 GB; re-pulled from ` +
    'GHCR on the next run)?';
  if (!pristine && !(yes || (await confirm(ask, { default: 'n' })))) {
    logger.info(`Kept the pristine image '${image}'.`);
    return;
  }
  if (!(await vmExists(image))) {
    logger.info(`Pristine image '${image}' does not exist — nothing to delete.`);
    return;
  }
  if ((await vmState(image)) === 'running') {
    logger.cmd(`tart stop ${image}`);
    await stopVm(image);
  }
  logger.cmd(`tart delete ${image}`);
  const res = await deleteVm(image);
  if (res.code === 0) {
    logger.ok(`Pristine image '${image}' deleted.`);
  } else {
    logger.warn(`'tart delete ${image}' failed — is it running?`);
  }
}
