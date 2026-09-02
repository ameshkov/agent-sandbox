// runners/ubuntu-shared.ts — step 4 for the Ubuntu backend: the shared
// host directory over HGFS (open-vm-tools' vmhgfs-fuse). Best-effort —
// the sandbox works without it, failures warn only, like the shell's
// setup_shared_folder. The vmrun side (tools gate + addSharedFolder with
// the "Already exists" case) is here; the guest mount runs over the ssh2
// session with the password piped into sudo -S.

import { existsSync } from 'node:fs';
import { logger } from '../lib/logger.js';
import { openSshSession, type SshCredentials } from '../lib/ssh.js';
import { enableSharedFolders, isVmRunning } from '../lib/vmrun.js';
import type { RunContext } from './framework.js';
import { addSharedFolderRetry, waitForTools } from './vmware-common.js';

/** The shared-folder step: register + enable the share with vmrun and
 *  mount it in the guest (skipped silently when no --work-dir / missing
 *  host dir / VM down — the shell's early-outs).
 *
 * @param context - The run context.
 * @param workVmx - The working VM vmx.
 * @param creds - The guest credentials (mount over ssh).
 */
export async function setupSharedFolder(
  context: RunContext,
  workVmx: string,
  creds: SshCredentials,
): Promise<void> {
  if (!context.workDir) {
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
  logger.info(`Sharing ${context.workDir} into the guest as 'work' (/mnt/hgfs/work).`);
  if (!(await waitForTools(workVmx))) {
    logger.warn(
      'VMware Tools did not report running — skipping the shared-directory share (re-run to retry).',
    );
    return;
  }
  await addSharedFolderRetry(workVmx, 'work', context.workDir);
  await enableSharedFolders(workVmx);
  await mountSharedFolder(creds);
}

/** Mounts the registered shares in the guest (vmhgfs-fuse needs root —
 *  sudo -S reads the password from the session's stdin).
 *
 * @param creds - The guest credentials.
 */
async function mountSharedFolder(creds: SshCredentials): Promise<void> {
  const session = await openSshSession(creds);
  try {
    const command =
      'mkdir -p /mnt/hgfs/work && sudo -S vmhgfs-fuse .host:/ /mnt/hgfs ' +
      '-o allow_other,default_permissions,uid=$(id -u),gid=$(id -g)';
    const res = await session.exec(command, { input: `${creds.password}\n`, timeoutMs: 60_000 });
    if (res.code !== 0) {
      logger.warn(
        'could not mount the shared folder in the guest — is vmhgfs-fuse available (open-vm-tools)?',
      );
      logger.warn('try manually: sudo vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other');
      return;
    }
    logger.ok('Shared folder mounted at /mnt/hgfs/work.');
  } catch (err) {
    logger.warn(`could not mount the shared folder in the guest: ${(err as Error).message}`);
  } finally {
    session.end();
  }
}
