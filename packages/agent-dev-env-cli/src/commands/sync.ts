// commands/sync.ts — `agent-dev-env sync <platform> [--yes]`: copy the
// host's user settings into the guest on demand (no VM restart), update
// the version marker and restart OpenChamber. macos | ubuntu-vmware per
// the plan; macOS lands in Phase 3 (tart transport), Ubuntu in Phase 4
// (ssh2 transport).

import { existsSync } from 'node:fs';
import { sleep } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { workingVmxPath } from '../lib/paths.js';
import type { Platform } from '../lib/platform.js';
import { tartAvailable, vmExists, vmState } from '../lib/tart.js';
import { findVmrun, getGuestIpAddress, isVmRunning } from '../lib/vmrun.js';
import { openSshSession } from '../lib/ssh.js';
import { syncUserSettings } from '../settings/macos-copy.js';
import { syncUserSettings as syncUbuntuSettings } from '../settings/ubuntu-copy.js';
import { resolveGuestCredentials } from '../runners/ubuntu-guest.js';
import { resolveRunOptions } from '../runners/options.js';
import { notYet } from './not-yet.js';

export interface SyncOptions {
  yes?: boolean;
}

/** Syncs the host's user settings into the guest.
 *
 * @param platform - The platform to sync.
 * @param options - --yes flag.
 * @returns The process exit code.
 */
export async function syncCmd(platform: Platform, options: SyncOptions): Promise<number> {
  if (platform === 'macos') {
    await syncMacos(options);
    return 0;
  }
  if (platform === 'ubuntu-vmware') {
    await syncUbuntu(options);
    return 0;
  }
  return notYet('sync', platform);
}

/** The macOS sync flow (VM must be running — `tart exec` needs it). */
async function syncMacos(options: SyncOptions): Promise<void> {
  if (!tartAvailable()) {
    logger.die("tart is not installed — run 'brew install cirruslabs/cli/tart' first.");
  }
  const runOptions = resolveRunOptions('macos', { yes: options.yes });
  const { vm } = runOptions;

  logger.title(`Syncing user settings into ${vm}`);
  if (!(await vmExists(vm))) {
    logger.die(`working VM '${vm}' not found — run 'agent-dev-env run macos' first.`);
  }
  if ((await vmState(vm)) !== 'running') {
    logger.die(`VM '${vm}' is not running — start it with 'agent-dev-env run macos' first.`);
  }

  const outcome = await syncUserSettings(vm, runOptions.home, runOptions.yes === true);
  if (outcome === 'copied') {
    logger.ok(`Done — settings synced into '${vm}'.`);
  }
}

/** The Ubuntu sync flow (VM must be running + sshd up — the settings
 *  travel over the ssh2 session).
 */
async function syncUbuntu(options: SyncOptions): Promise<void> {
  if (!findVmrun()) {
    logger.die(
      'vmrun not found — install VMware Fusion (free for personal use) or set FUSION_APP_PATH.',
    );
  }
  const runOptions = resolveRunOptions('ubuntu-vmware', { yes: options.yes });
  const vmx = workingVmxPath('ubuntu-vmware', runOptions.image);

  logger.title(`Syncing user settings into ${vmx}`);
  if (!existsSync(vmx)) {
    logger.die(`working VM '${vmx}' not found — run 'agent-dev-env run ubuntu-vmware' first.`);
  }
  if (!(await isVmRunning(vmx))) {
    logger.die(
      `VM '${vmx}' is not running — start it with 'agent-dev-env run ubuntu-vmware' first.`,
    );
  }

  const ip = await waitGuestIp(vmx);
  const creds = resolveGuestCredentials(runOptions.image, runOptions.env, ip);
  const session = await openSshSession(creds);
  try {
    const outcome = await syncUbuntuSettings(
      session,
      runOptions.home,
      runOptions.yes === true,
      creds.password,
    );
    if (outcome === 'copied') {
      logger.ok(`Done — settings synced into '${vmx}'.`);
    }
  } finally {
    session.end();
  }
}

/** Waits for the guest IP (bounded per call; the sync cannot proceed
 *  without it).
 *
 * @param vmx - The working VM vmx.
 * @returns The guest IP.
 */
async function waitGuestIp(vmx: string): Promise<string> {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    const ip = await getGuestIpAddress(vmx);
    if (ip) {
      return ip;
    }
    await sleep(2000);
  }
  return logger.die('timed out waiting for the guest IP — are open-vm-tools running in the guest?');
}
