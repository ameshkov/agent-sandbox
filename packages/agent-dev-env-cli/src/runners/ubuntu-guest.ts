// runners/ubuntu-guest.ts — the guest side of the Ubuntu step 3: the
// credentials (from the image's vars file, UBUNTU_PASSWORD override),
// where the bundled guest agent lives, how it is uploaded over SFTP and
// how it is run (upload → sudo install → status), plus the status-line
// parsing. The transport is the ssh2 session (lib/ssh.ts) — the twin of
// runners/macos-guest.ts, which runs over `tart exec`.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { varsFor } from '../lifecycle/catalog.js';
import { logger } from '../lib/logger.js';
import type { SshCredentials, SshSession } from '../lib/ssh.js';
import type { VarValue } from '../lib/vars.js';
import type { RunContext, RunState } from './framework.js';
import { resolveImage } from '../lifecycle/catalog.js';

/** The guest's agent install dir (image-fixed home `/home/admin`). */
const GUEST_LIB_DIR = '/home/admin/.local/lib/agent-dev-env';

/** The absolute guest-agent path. */
export const GUEST_AGENT = `${GUEST_LIB_DIR}/guest-agent-ubuntu.js`;

/** The guest's sshd port (fixed in the image; no hostfwd — the VM sits
 *  on Fusion's NAT and the host reaches it directly). */
const GUEST_SSH_PORT = 22;

/** The bundled Ubuntu guest agent (single-file, node-only). */
function guestAgentPath(): string {
  return fileURLToPath(new URL('../assets/guest/guest-agent-ubuntu.js', import.meta.url));
}

/** @internal — resolves the guest credentials from the image's vars file
 *  (+ UBUNTU_PASSWORD override). Pure so the fallbacks are testable.
 *
 * @param vars - The vars file values.
 * @param env - Environment (UBUNTU_PASSWORD).
 * @param ip - The guest IP.
 * @returns The credentials.
 * @throws Error when no ssh_password is available.
 */
export function guestCredentials(
  vars: Record<string, VarValue>,
  env: Record<string, string | undefined>,
  ip: string,
): SshCredentials {
  const username =
    typeof vars.ssh_username === 'string' && vars.ssh_username.trim() ? vars.ssh_username : 'admin';
  const password =
    env.UBUNTU_PASSWORD ?? (typeof vars.ssh_password === 'string' ? vars.ssh_password : '');
  if (!password) {
    throw new Error(
      'could not read ssh_password from the vars file — set UBUNTU_PASSWORD to the guest password.',
    );
  }
  return { host: ip, port: GUEST_SSH_PORT, username, password };
}

/** The credentials for the current run (image vars + env + guest IP).
 *
 * @param image - The image name.
 * @param env - Environment.
 * @param ip - The guest IP.
 * @returns The credentials.
 */
export function resolveGuestCredentials(
  image: string,
  env: Record<string, string | undefined>,
  ip: string,
): SshCredentials {
  return guestCredentials(varsFor(resolveImage(image)), env, ip);
}

/** Reports the path of the node binary inside the guest (opencode needs
 *  it, so the image ships it; resolve once per session like the mac
 *  backend).
 *
 * @param session - The connected guest session.
 * @returns The absolute node path, or undefined when not found.
 */
export async function findGuestNode(session: SshSession): Promise<string | undefined> {
  const res = await session.exec('sh -lc "command -v node"');
  const node = res.code === 0 ? res.stdout.trim() : '';
  return node && node.startsWith('/') ? node : undefined;
}

/** Uploads the bundled guest agent and runs `install` (idempotent:
 *  systemd user units rewritten + the bridge env exports). Runs as the
 *  guest user — the agent's systemd units live under the user's
 *  ~/.config/systemd/user, and `systemctl --user` must target the admin
 *  session (running the agent through sudo would place them under /root;
 *  the agent then falls back to the user-level ~/.profile exports).
 *
 * @param session - The connected guest session.
 * @param node - The guest's node binary.
 * @param hostAlias - The NAT host address the bridges point at.
 * @param context - The run context (ports).
 */
export async function ensureGuestAgent(
  session: SshSession,
  node: string,
  hostAlias: string,
  context: RunContext,
): Promise<void> {
  const mkdir = await session.exec(`mkdir -p ${GUEST_LIB_DIR}`);
  if (mkdir.code !== 0) {
    logger.warn(`could not prepare the guest agent dir (ssh: ${mkdir.code}).`);
    return;
  }
  try {
    await session.sftpWrite(GUEST_AGENT, readFileSync(guestAgentPath()));
  } catch (err) {
    logger.warn(`could not upload the guest agent: ${(err as Error).message}`);
    return;
  }
  const install = await session.exec(
    `${node} ${GUEST_AGENT} install ` +
      `--agent-port ${context.agentPort} --docker-port ${context.dockerPort} ` +
      `--host-alias ${hostAlias}`,
    { timeoutMs: 60_000 },
  );
  if (install.code !== 0) {
    logger.warn(`guest agent install failed (ssh: ${install.code}).`);
    return;
  }
  logger.ok('Guest agent installed (SSH agent + Docker bridges persistent).');
}

/** Parses the guest agent's machine-readable status lines — shared by
 *  the Ubuntu and Windows guests (identical bridge-status format).
 *
 * @param output - The `guest-agent status` stdout.
 * @returns The per-role bridge state (present per reported line).
 */
export function parseGuestStatus(output: string): { sshAgent?: boolean; docker?: boolean } {
  const status: { sshAgent?: boolean; docker?: boolean } = {};
  for (const line of output.split('\n')) {
    const match = /^bridge-status:(ssh-agent|docker)=(up|down)$/.exec(line.trim());
    if (!match) {
      continue;
    }
    if (match[1] === 'ssh-agent') {
      status.sshAgent = match[2] === 'up';
    } else {
      status.docker = match[2] === 'up';
    }
  }
  return status;
}

/** Runs `guest-agent status` and folds the bridge-status lines into the
 *  run state.
 *
 * @param session - The connected guest session.
 * @param state - The accumulated run state.
 * @param node - The guest's node binary.
 */
export async function readGuestStatus(
  session: SshSession,
  state: RunState,
  node: string,
): Promise<void> {
  const res = await session.exec(`${node} ${GUEST_AGENT} status`, { timeoutMs: 20_000 });
  if (res.code !== 0) {
    return;
  }
  const status = parseGuestStatus(res.stdout);
  if (status.sshAgent !== undefined) {
    state.bridges.agent.guestUp = status.sshAgent;
  }
  if (status.docker !== undefined) {
    state.bridges.docker.guestUp = status.docker;
  }
}
