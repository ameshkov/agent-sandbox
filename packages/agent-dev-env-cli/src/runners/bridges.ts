// runners/bridges.ts — the host side of the SSH agent + Docker bridges:
// socket discovery, the port probe (the legacy "is a listener already
// bound" check), and the detached spawn of the bundled bridge.js (the
// socat replacement). The guest side lives in the
// per-platform guest agents (launchd/schtasks/systemd).
//
// The bridge is spawned detached with a pidfile under the logs/state dir
// and keeps running after the CLI exits (the VM needs it while it runs);
// `stop` kills it by pidfile. Idempotent: when a listener is already up,
// nothing is spawned.

import net from 'node:net';
import { lstatSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isAlive, killTree, readPidFile, spawnDetached } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { paths } from '../lib/paths.js';

export type BridgeRole = 'ssh-agent' | 'docker';

/** The bundled bridge entry — where copy-assets.mjs puts it. */
function bridgeJsPath(): string {
  // dist/runners/bridges.js -> dist/assets/bridge/bridge.js
  return fileURLToPath(new URL('../assets/bridge/bridge.js', import.meta.url));
}

/** @internal — pidfile for a host bridge (logs/state dir). */
export function bridgePidFile(role: BridgeRole): string {
  return join(paths.logs, `bridge-${role}.pid`);
}

/** @internal — log file for a host bridge. */
export function bridgeLogFile(role: BridgeRole): string {
  return join(paths.logs, `bridge-${role}.log`);
}

/** Whether the path is a Unix socket. */
function isUnixSocket(path: string): boolean {
  try {
    return lstatSync(path).isSocket();
  } catch {
    return false;
  }
}

/** The host's SSH agent socket when it is overridden by a password
 *  manager's agent (Bitwarden, 1Password, ...). The stock macOS launchd
 *  agent (a socket under /var/run/com.apple.launchd.*) is NOT bridged.
 *
 * @param env - Environment (SSH_AUTH_SOCK).
 * @param home - Host home directory (unused, kept for signature parity).
 * @returns The socket path, or undefined when nothing is bridged.
 */
export function findHostAgentSocket(
  env: Record<string, string | undefined> = process.env,
  _home: string = process.env.HOME ?? '',
): string | undefined {
  const sock = env.SSH_AUTH_SOCK;
  if (!sock || /^\/var\/run\/com\.apple\.launchd\..*\/Listeners$/.test(sock)) {
    return undefined;
  }
  if (isUnixSocket(sock)) {
    return sock;
  }
  logger.warn(`SSH_AUTH_SOCK points to '${sock}', but no such socket exists.`);
  return undefined;
}

/** The host's Docker engine socket — the engines the sandbox supports:
 *  Docker Desktop (4.30+), Colima, OrbStack, then the legacy /var/run.
 *
 * @param home - Host home directory.
 * @returns The socket path, or undefined when no engine is running.
 */
export function findHostDockerSocket(home: string): string | undefined {
  const candidates = [
    join(home, '.docker', 'run', 'docker.sock'),
    join(home, '.colima', 'default', 'docker.sock'),
    join(home, '.orbstack', 'run', 'docker.sock'),
    '/var/run/docker.sock',
  ];
  return candidates.find((candidate) => isUnixSocket(candidate));
}

/** @internal — TCP probe: can a client connect to host:port?
 *
 * @param host - Bind/target host.
 * @param port - TCP port.
 * @param timeoutMs - Probe timeout (default 1000).
 * @returns True when a connection is accepted.
 */
export function canConnectTcp(host: string, port: number, timeoutMs = 1000): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    const done = (ok: boolean): void => {
      socket.destroy();
      resolve(ok);
    };
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
    setTimeout(() => done(false), timeoutMs);
  });
}

export type StartBridgeResult =
  { state: 'already-up' } | { state: 'started'; pid: number } | { state: 'failed' };

/** Spawns the detached host bridge (or reports it is already up).
 *
 * @param args - role (pidfile/log naming), bind host + port and the
 *   forward socket (unix path on the host).
 * @returns The outcome; nothing is spawned when the port is already
 *   served.
 */
export async function startHostBridge(args: {
  role: BridgeRole;
  bindHost: string;
  port: number;
  forwardSocket: string;
}): Promise<StartBridgeResult> {
  if (await canConnectTcp(args.bindHost, args.port)) {
    logger.ok(`A listener is already bound to TCP port ${args.port} — assuming the bridge is up.`);
    return { state: 'already-up' };
  }

  const pidFile = bridgePidFile(args.role);
  const pid = spawnDetached(
    process.execPath,
    [
      bridgeJsPath(),
      '--listen',
      `tcp:${args.bindHost}:${args.port}`,
      '--forward',
      `unix:${args.forwardSocket}`,
      '--pidfile',
      pidFile,
    ],
    { logFile: bridgeLogFile(args.role) },
  );
  if (pid <= 0) {
    logger.warn('host bridge failed to start — check the agent socket path.');
    return { state: 'failed' };
  }

  // Give the bridge a moment to bind; a dead socket path makes the
  // listener exit immediately (the legacy `kill -0` sleep-1 check).
  await new Promise((resolve) => setTimeout(resolve, 1000));
  if (!isAlive(pid) && !readPidFile(pidFile)) {
    rmSync(pidFile, { force: true });
    logger.warn('host bridge exited immediately — check the agent socket path.');
    return { state: 'failed' };
  }
  logger.ok(`Host bridge is up (pid ${pid}).`);
  return { state: 'started', pid };
}

/** Stops the detached bridge for a role: pidfile → killTree, pidfile
 *  removed. No-op when nothing is running (idempotent, like the legacy
 *  stop script's "no listener" branch).
 *
 * @param role - The bridge role.
 * @returns The pid when something was stopped, undefined otherwise.
 */
export async function stopHostBridge(role: BridgeRole): Promise<number | undefined> {
  const pidFile = bridgePidFile(role);
  const pid = readPidFile(pidFile);
  if (pid !== undefined && isAlive(pid)) {
    await killTree(pid);
    rmSync(pidFile, { force: true });
    return pid;
  }
  rmSync(pidFile, { force: true });
  return undefined;
}

/** Ensures the logs/state dir exists (pidfiles + logs for the bridges
 *  and the tart run log).
 */
export function ensureBridgeDir(): void {
  mkdirSync(dirname(bridgePidFile('ssh-agent')), { recursive: true });
}
