// runners/macos-bridges.ts — step 3 for the macOS backend: the host side
// of the SSH agent + Docker bridges (socket discovery + detached bridge.js
// spawn). The guest side (upload/install/status) lives in macos-guest.ts,
// the rules step in macos-rules.ts; this module wires them together —
// port of run-macos-sandbox.sh §step 3, with the socat pair replaced by
// the Node forwarder on both sides.

import { sleep } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { execVm, findGuestNode, gatewayFromVmIp, vmIp } from '../lib/tart.js';
import { findHostAgentSocket, findHostDockerSocket, startHostBridge } from './bridges.js';
import type { RunContext, RunState } from './framework.js';
import { ensureGuestAgent, readGuestStatus } from './macos-guest.js';
import { installAgentRules } from './macos-rules.js';

/** The macOS step 3: guest agent + bridges (agent/docker) + rules. The
 *  guest agent is installed up front (rules need it; install is
 *  idempotent), then each bridge is wired independently.
 */
export async function macosBridges(context: RunContext, state: RunState): Promise<void> {
  const node = await findGuestNode(context.vm);
  if (!node) {
    logger.warn('node not found in the guest — skipping the guest bridges and rules.');
    return;
  }
  const gateway = await resolveGateway(context, state);
  await ensureGuestAgent(context, node, gateway);

  if (context.options.noAgent) {
    logger.info('Skipping SSH agent bridge setup (--no-agent).');
  } else {
    await setupSshAgent(context, state, node);
  }
  if (context.options.noDocker) {
    logger.info('Skipping Docker bridge setup (--no-docker).');
  } else {
    await setupDockerBridge(context, state, node);
  }
  await installAgentRules(context, state, node);
}

/** The host's address on Tart's VM network (`.1` of the VM's /24),
 *  retrying the IP fetch — it can fail right after boot.
 */
async function resolveGateway(context: RunContext, state: RunState): Promise<string | undefined> {
  let ip = state.vmIp;
  for (let attempt = 0; attempt < 5 && !ip; attempt += 1) {
    ip = await vmIp(context.vm);
    if (!ip) {
      await sleep(2000);
    }
  }
  state.vmIp = ip;
  if (!ip) {
    return undefined;
  }
  return gatewayFromVmIp(ip);
}

async function setupSshAgent(context: RunContext, state: RunState, node: string): Promise<void> {
  const sock = findHostAgentSocket(context.options.env, context.options.home);
  if (!sock) {
    logger.info('No SSH agent override detected — using the default macOS agent.');
    logger.info(
      'To share a password manager\u2019s agent (Bitwarden, 1Password, ...), ' +
        'enable its SSH agent on the host and re-run.',
    );
    return;
  }
  logger.ok(`Host SSH agent socket found: ${sock}`);
  logger.info(
    `Bridging it into '${context.vm}' on TCP port ${context.agentPort} (see docs/ssh-agent.md).`,
  );

  if (!(await startBridge(context, state, 'ssh-agent', sock))) {
    return;
  }
  await readGuestStatus(context, state, node);
  if (state.bridges.agent.guestUp) {
    logger.ok(`Guest bridge is up: /tmp/ssh-agent.sock -> host TCP ${context.agentPort}`);
  } else {
    logger.warn(
      'guest bridge did not start — run the guest commands from docs/ssh-agent.md manually.',
    );
  }
}

async function setupDockerBridge(
  context: RunContext,
  state: RunState,
  node: string,
): Promise<void> {
  const sock = findHostDockerSocket(context.options.home);
  if (!sock) {
    logger.info('No Docker engine socket found on the host (Docker Desktop, Colima, OrbStack).');
    logger.info('Start an engine on the host and re-run to bridge it into the guest.');
    return;
  }
  logger.ok(`Host Docker engine socket found: ${sock}`);
  logger.info(`Bridging it into '${context.vm}' on TCP port ${context.dockerPort}.`);

  if (!(await startBridge(context, state, 'docker', sock))) {
    return;
  }
  await readGuestStatus(context, state, node);
  if (state.bridges.docker.guestUp) {
    logger.ok(
      `Guest Docker bridge is up: ~/.docker/run/docker.sock -> host TCP ${context.dockerPort}`,
    );
  } else {
    logger.warn('guest Docker bridge did not start — check the guest agent install.');
    return;
  }
  await verifyGuestDocker(context, state);
}

/** The shared bridge start: gateway resolution + host spawn + state
 *  bookkeeping. Returns false when the bridge was skipped.
 */
async function startBridge(
  context: RunContext,
  state: RunState,
  role: 'ssh-agent' | 'docker',
  socket: string,
): Promise<boolean> {
  const gateway = await resolveGateway(context, state);
  if (!gateway) {
    logger.warn(`could not determine the host gateway address ('tart ip ${context.vm}' failed).`);
    return false;
  }
  const result = await startHostBridge({
    role,
    bindHost: gateway,
    port: role === 'ssh-agent' ? context.agentPort : context.dockerPort,
    forwardSocket: socket,
  });
  if (result.state === 'failed') {
    logger.warn(`skipping the ${role === 'ssh-agent' ? 'SSH agent' : 'Docker'} bridge.`);
    return false;
  }
  const bridge = role === 'ssh-agent' ? state.bridges.agent : state.bridges.docker;
  bridge.bridged = true;
  bridge.socket = socket;
  bridge.pid = result.state === 'started' ? result.pid : undefined;
  return true;
}

/** End-to-end check: can the guest's docker CLI reach the host engine
 *  through the bridge? Retries briefly (the engine may still be
 *  starting), like the shell's verify_guest_docker (15 x 1 s).
 */
async function verifyGuestDocker(context: RunContext, state: RunState): Promise<void> {
  const probe = 'export PATH="/opt/homebrew/bin:$PATH"; docker info --format "{{.ServerVersion}}"';
  for (let attempt = 0; attempt < 15; attempt += 1) {
    const res = await execVm(context.vm, ['sh', '-c', probe]);
    const version = res.code === 0 ? res.stdout.trim() : '';
    if (version) {
      state.bridges.docker.serverVersion = version;
      state.bridges.docker.engineUp = true;
      logger.ok(`Docker engine is reachable from the guest (server version ${version}).`);
      return;
    }
    await sleep(1000);
  }
  logger.warn('Docker engine not reachable from the guest yet — is it running on the host?');
  logger.warn('The bridge reconnects on its own once it is; re-run this script to re-check.');
}
