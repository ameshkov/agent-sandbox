// runners/windows-shared.ts — step 4 for the Windows backend: the shared
// host directory over HGFS (best-effort, like the Ubuntu backend). VMware
// Tools for Windows Arm ships no HGFS driver, so Windows 11 ARM guests on
// Apple silicon can never mount the share — detected via the vmx guestos
// string and skipped with a warning (the legacy hgfs_unsupported). The
// vmrun registration path is kept for parity: a share registered by a
// previous run persists in the vmx.

import { existsSync, readFileSync } from 'node:fs';
import { logger } from '../lib/logger.js';
import { enableSharedFolders, isVmRunning } from '../lib/vmrun.js';
import type { RunContext, RunState } from './framework.js';
import { addSharedFolderRetry, waitForTools } from './vmware-common.js';

/** @internal — whether the VM's guest os string is an ARM Windows guest
 *  (VMware Tools for Windows Arm has no HGFS driver — the guest can never
 *  mount \\vmware-host\Shared Folders\work even when the host publishes
 *  it). Pure for the co-located test.
 *
 * @param vmxContent - The raw vmx text.
 * @returns True when the guest cannot mount HGFS shares.
 */
export function hgfsUnsupported(vmxContent: string): boolean {
  return /^[ \t]*guestos[ \t]*=[ \t]*"arm-/m.test(vmxContent);
}

/** The shared-folder step: skipped with the platform warning for ARM
 *  guests; otherwise the vmrun register + enable flow with the tools
 *  gate. Failures warn only — the sandbox works without the share.
 *
 * @param context - The run context (workDir).
 * @param state - The accumulated run state (sharedFolderSkipped).
 * @param workVmx - The working VM vmx.
 */
export async function setupWindowsSharedFolder(
  context: RunContext,
  state: RunState,
  workVmx: string,
): Promise<void> {
  if (!context.workDir) {
    return;
  }
  let vmxContent = '';
  try {
    vmxContent = readFileSync(workVmx, 'utf8');
  } catch {
    // no vmx — nothing to share; the running check below reports.
  }
  if (vmxContent && hgfsUnsupported(vmxContent)) {
    state.sharedFolderSkipped = true;
    logger.warn(
      'shared host folder not supported: VMware Tools for Windows 11 ARM guests on ' +
        'Apple silicon has no HGFS driver, so the guest can never see ' +
        '\\\\vmware-host\\Shared Folders\\work.',
    );
    logger.warn(
      'use an alternative instead (SMB share from the Mac, SSH/SCP, RDP clipboard, git) ' +
        '— see docs/windows-vmware.md.',
    );
    return;
  }
  if (!existsSync(context.workDir)) {
    logger.warn(
      `work directory '${context.workDir}' does not exist — skipping the shared-directory share.`,
    );
    return;
  }
  if (!(await isVmRunning(workVmx))) {
    logger.warn('shared folder skipped — the VM is not running.');
    return;
  }
  logger.info(
    `Sharing ${context.workDir} into the guest as 'work' ` +
      '(\\\\vmware-host\\Shared Folders\\work).',
  );
  if (!(await waitForTools(workVmx))) {
    logger.warn(
      'VMware Tools did not report running — skipping the shared-directory share (re-run to retry).',
    );
    return;
  }
  await addSharedFolderRetry(workVmx, 'work', context.workDir);
  await enableSharedFolders(workVmx);
  logger.ok('Shared folder registered (best-effort — HGFS must be enabled by VMware Tools).');
}
