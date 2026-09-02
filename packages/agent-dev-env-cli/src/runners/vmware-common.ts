// runners/vmware-common.ts — the run-time helpers the two VMware backends
// (ubuntu-vmware and windows-vmware) share: the vmrun prereq, the
// stop-running-VM restart flow, the bounded guest-IP wait, the
// VMware-Tools wait and the bridge cleanup. Extracted from the ubuntu
// backend when the windows backend landed (Phase 5) — one implementation
// for both, with the platform label for the runners' messages.

import { killTree, sleep } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { confirmDefault } from '../lib/prompt.js';
import {
  addSharedFolder,
  checkToolsState,
  findVmrun,
  getGuestIpAddress,
  isVmRunning,
  sharedFolderAlreadyExists,
  stopVm,
  waitForVmNotRunning,
} from '../lib/vmrun.js';
import type { RunContext } from './framework.js';

/** vmrun prereq (same message as doctor/status).
 *
 * @returns The resolved vmrun path.
 */
export function requireVmrun(): void {
  if (!findVmrun()) {
    logger.die(
      'vmrun not found — install VMware Fusion (free for personal use) or set FUSION_APP_PATH.',
    );
  }
}

/** Stops a VM left running by a previous run before the boot (the old
 *  VM holds the clone's disks; the legacy stop_running_vm — restart
 *  confirm defaults to no).
 *
 * @param context - The run context.
 * @param workVmx - The working VM vmx.
 * @param platform - The platform id (stop-hint message).
 */
export async function stopRunningVm(
  context: RunContext,
  workVmx: string,
  platform: string,
): Promise<void> {
  if (!(await isVmRunning(workVmx))) {
    return;
  }
  if (
    !(await confirmDefault('The sandbox VM is already running — restart it?', {
      default: 'n',
      yes: context.options.yes,
    }))
  ) {
    logger.die(`aborted — the VM is already running. Stop it with: agent-dev-env stop ${platform}`);
  }
  logger.cmd(`vmrun -T fusion stop ${workVmx}`);
  await stopVm(workVmx);
  process.stdout.write('    Waiting for the VM to stop');
  if (await waitForVmNotRunning(workVmx, 60, 2000)) {
    process.stdout.write(` ${logger.color('green')}stopped${logger.reset()}\n`);
  } else {
    process.stdout.write(` ${logger.color('yellow')}failed${logger.reset()}\n`);
    logger.warn(`'${workVmx}' is still running — stop it manually with 'vmrun -T fusion stop'.`);
  }
  await sleep(1000);
}

/** Polls vmrun getGuestIPAddress (bounded per call; strictly a dotted
 *  quad — the "Tools not running" error text must never become the IP).
 *
 * @param workVmx - The working VM vmx.
 * @returns The guest IP.
 */
export async function waitGuestIp(workVmx: string): Promise<string> {
  process.stdout.write('    Waiting for the guest IP (open-vm-tools; up to 15 min)');
  for (let attempt = 0; attempt < 180; attempt += 1) {
    const ip = await getGuestIpAddress(workVmx);
    if (ip) {
      process.stdout.write(` ${logger.color('green')}done${logger.reset()}\n`);
      return ip;
    }
    process.stdout.write('.');
    await sleep(5000);
  }
  process.stdout.write(` ${logger.color('yellow')}failed${logger.reset()}\n`);
  return logger.die('timed out waiting for the guest IP — are open-vm-tools running in the guest?');
}

/** Polls checkToolsState until vmrun reports "running" (the tools can
 *  still be starting when the IP and sshd already answer — vmrun
 *  addSharedFolder then fails).
 *
 * @param workVmx - The working VM vmx.
 * @returns True when the tools report running within the window.
 */
export async function waitForTools(workVmx: string): Promise<boolean> {
  process.stdout.write('    Waiting for VMware Tools to be running');
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if ((await checkToolsState(workVmx)) === 'running') {
      process.stdout.write(` ${logger.color('green')}done${logger.reset()}\n`);
      return true;
    }
    process.stdout.write('.');
    await sleep(5000);
  }
  process.stdout.write(` ${logger.color('yellow')}failed${logger.reset()}\n`);
  return false;
}

/** Registers the share (4 x 10 s retries — the tools state can flip back
 *  after waitForTools; "Already exists" from a previous run is ok).
 *
 * @param workVmx - The working VM vmx.
 * @param name - The share name.
 * @param path - The host directory.
 */
export async function addSharedFolderRetry(
  workVmx: string,
  name: string,
  path: string,
): Promise<void> {
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    const res = await addSharedFolder(workVmx, name, path);
    if (res.code === 0) {
      return;
    }
    if (sharedFolderAlreadyExists(`${res.stdout}${res.stderr}`)) {
      logger.ok(
        'Shared folder already registered (from a previous run — the share persists in the vmx).',
      );
      return;
    }
    if (attempt < 4) {
      logger.warn(
        `addSharedFolder failed (${res.stderr.trim()}) — retrying in 10 s (attempt ${attempt}/4).`,
      );
      await sleep(10_000);
    }
  }
  logger.warn('addSharedFolder failed after 4 attempts — is VMware Tools up? Continuing.');
}

/** The foreground wait: poll vmrun list until the VM stops; a Cmd+C stops
 *  it through the same vmrun path as the shell's EXIT trap. The VM must
 *  already be up (the working vmx exists).
 *
 * @param workVmx - The working VM vmx.
 */
export async function waitForForegroundVmStop(workVmx: string): Promise<void> {
  let stopping = false;
  const onSignal = (): void => {
    if (stopping) {
      return;
    }
    stopping = true;
    logger.info('Stopping the VM (Cmd+C)...');
    // Plain `vmrun stop` — the shell's EXIT trap parity (hard power-off;
    // the poll loop waits for the running list to clear).
    void stopVm(workVmx, 'hard');
  };
  process.on('SIGINT', onSignal);
  process.on('SIGTERM', onSignal);
  logger.info('Waiting for the VM to stop (Cmd+C to stop it now)...');
  try {
    while (await isVmRunning(workVmx)) {
      await sleep(3000);
    }
  } finally {
    process.removeListener('SIGINT', onSignal);
    process.removeListener('SIGTERM', onSignal);
  }
  logger.info('VM stopped.');
}

/** Kills one of this run's bridges (the foreground-mode teardown; in
 *  background mode the bridges stay up, outliving the CLI by design).
 *
 * @param pid - The bridge pid this run started (undefined = not ours).
 * @param label - The bridge label (agent bridge / Docker bridge).
 */
export async function cleanupRunBridge(pid: number | undefined, label: string): Promise<void> {
  if (pid === undefined) {
    return;
  }
  await killTree(pid);
  logger.info(`Stopped the host ${label} (pid ${pid}).`);
}
