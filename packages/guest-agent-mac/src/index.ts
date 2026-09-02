// index.ts — guest-agent-mac CLI. Runs inside the macOS sandbox guest
// (bundled single-file, node-only): installs/bridges the host SSH agent
// and Docker engine into the guest and manages the agent rules.
//
//   guest-agent-mac install [--agent-port N] [--docker-port N] [--host-alias A]
//   guest-agent-mac bridge <ssh-agent|docker> [--listen EP] [--forward EP] [--port N]
//   guest-agent-mac status
//   guest-agent-mac rules [--force]
//   guest-agent-mac uninstall

import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runBridge } from 'bridge-core';
import { parseEndpoint } from 'bridge-core/endpoints';
import { canConnect } from 'bridge-core/probe';
import { applyRules, rulesAction } from 'guest-rules';
import {
  appendBlockIfMissing,
  dockerContextArgs,
  GUEST_AGENT_SOCKET,
  LAUNCHD_LABELS,
  launchdPlist,
  removeBlock,
  sshConfigBlock,
  ZPROFILE_MARKERS,
  zprofileAgentBlock,
  zprofileDockerBlock,
  type LaunchdBridge,
} from './system.js';

const AGENT_PATH = fileURLToPath(import.meta.url);
const NODE_PATH = process.execPath;
const HOME = homedir();
const LAUNCH_AGENTS_DIR = join(HOME, 'Library', 'LaunchAgents');
const DOCKER_SOCKET = join(HOME, '.docker', 'run', 'docker.sock');

const DEFAULTS = {
  agentPort: 4100,
  dockerPort: 4101,
} as const;

async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv;
  try {
    switch (cmd) {
      case 'install':
        return install(rest);
      case 'bridge':
        return bridgeCommand(rest);
      case 'status':
        return status();
      case 'rules':
        return rulesCommand(rest);
      case 'uninstall':
        return uninstall();
      default:
        process.stderr.write(usage());
        return 1;
    }
  } catch (err) {
    process.stderr.write(`guest-agent-mac: ${(err as Error).message}\n`);
    return 1;
  }
}

function usage(): string {
  return [
    'usage: guest-agent-mac <install|bridge|status|rules|uninstall> [options]',
    '  install [--agent-port N] [--docker-port N] [--host-alias A]',
    '  bridge <ssh-agent|docker> [--listen EP] [--forward EP] [--port N] [--host-alias A]',
    '  rules [--force]  (content on stdin)',
    '',
  ].join('\n');
}

function argValue(argv: string[], flag: string): string | undefined {
  const index = argv.indexOf(flag);
  return index === -1 ? undefined : argv[index + 1];
}

/** Parses the default-gateway line from `netstat -nr` output. */
export function gatewayFromNetstat(output: string): string | undefined {
  for (const line of output.split('\n')) {
    if (!/\sdefault\s/.test(line)) {
      continue;
    }
    const fields = line.trim().split(/\s+/);
    const gw = fields[1];
    if (gw) {
      return gw;
    }
  }
  return undefined;
}

function defaultGateway(): string | undefined {
  const res = execFileSync('netstat', ['-nr'], { encoding: 'utf8' });
  return gatewayFromNetstat(res);
}

function bridgeFor(role: string, port: number, hostAlias: string): LaunchdBridge {
  return {
    label: LAUNCHD_LABELS[role as keyof typeof LAUNCHD_LABELS],
    nodePath: NODE_PATH,
    agentPath: AGENT_PATH,
    role,
    port,
    hostAlias,
  };
}

function install(argv: string[]): number {
  const hostAlias =
    argValue(argv, '--host-alias') ??
    defaultGateway() ??
    (() => {
      throw new Error('could not determine the host gateway (--host-alias)');
    })();
  const agentPort = Number(argValue(argv, '--agent-port') ?? DEFAULTS.agentPort);
  const dockerPort = Number(argValue(argv, '--docker-port') ?? DEFAULTS.dockerPort);

  mkdirSync(LAUNCH_AGENTS_DIR, { recursive: true });
  const uid = execFileSync('id', ['-u'], { encoding: 'utf8' }).trim();

  for (const [role, port] of [
    ['ssh-agent', agentPort],
    ['docker', dockerPort],
  ] as const) {
    const bridge = bridgeFor(role, port, hostAlias);
    const plistPath = join(LAUNCH_AGENTS_DIR, `${bridge.label}.plist`);
    writeFileSync(plistPath, launchdPlist(bridge, DOCKER_SOCKET));
    reloadAgent(bridge.label, plistPath, uid);
    process.stdout.write(`installed:${role} (${bridge.label}, port ${port})\n`);
  }

  appendZprofile();
  appendSshConfig();
  setupDockerContext();
  return 0;
}

/** Idempotent reinstall: drop the loaded job first (overwriting the
 *  plist alone would keep the old args), then bootstrap the new one. */
function reloadAgent(label: string, plistPath: string, uid: string): void {
  try {
    execFileSync('launchctl', ['bootout', `gui/${uid}/${label}`], { stdio: 'ignore' });
  } catch {
    // not loaded — nothing to unload
  }
  loadAgent(label, plistPath, uid);
}

function loadAgent(label: string, plistPath: string, uid: string): void {
  try {
    execFileSync('launchctl', ['bootstrap', `gui/${uid}`, plistPath], { stdio: 'ignore' });
  } catch {
    try {
      execFileSync('launchctl', ['load', plistPath], { stdio: 'ignore' });
    } catch {
      process.stderr.write(`warning: could not load ${label}\n`);
    }
  }
}

/** Point the guest's docker CLI at the bridged socket: create/update the
 *  `host` context (docker is npm-free but Homebrew-installed, so resolve
 *  it via a login shell) and make it the default.
 */
function setupDockerContext(): void {
  const docker = findDockerPath();
  if (!docker) {
    process.stderr.write('warning: docker CLI not found — skipping the docker context\n');
    return;
  }
  const [create, update, use] = dockerContextArgs(docker, DOCKER_SOCKET);
  const created = spawnSync(create[0], create.slice(1), { stdio: 'ignore' });
  if (created.status !== 0) {
    spawnSync(update[0], update.slice(1), { stdio: 'ignore' });
  }
  const used = spawnSync(use[0], use.slice(1), { stdio: 'ignore' });
  if (used.status === 0) {
    process.stdout.write('installed:docker context host\n');
  }
}

function findDockerPath(): string | undefined {
  const res = spawnSync('sh', ['-lc', 'command -v docker'], { encoding: 'utf8' });
  const docker = res.status === 0 ? res.stdout.trim() : '';
  return docker && docker.startsWith('/') ? docker : undefined;
}

function appendZprofile(): void {
  const zprofile = join(HOME, '.zprofile');
  let content = readMaybe(zprofile);
  content = appendBlockIfMissing(content, zprofileAgentBlock(), ZPROFILE_MARKERS.agent);
  content = appendBlockIfMissing(content, zprofileDockerBlock(), ZPROFILE_MARKERS.env);
  writeFileSync(zprofile, content);
}

function appendSshConfig(): void {
  const dir = join(HOME, '.ssh');
  mkdirSync(dir, { recursive: true });
  const config = join(dir, 'config');
  const content = appendBlockIfMissing(
    readMaybe(config),
    sshConfigBlock(),
    '# SSH agent bridge to the host (see docs/ssh-agent.md)',
  );
  writeFileSync(config, content);
  execFileSync('chmod', ['700', dir]);
  execFileSync('chmod', ['600', config]);
}

function bridgeCommand(argv: string[]): Promise<number> {
  const role = argv[0];
  if (role !== 'ssh-agent' && role !== 'docker') {
    throw new Error(`unknown bridge role '${role}' (ssh-agent|docker)`);
  }
  const port = Number(
    argValue(argv, '--port') ?? DEFAULTS[role === 'ssh-agent' ? 'agentPort' : 'dockerPort'],
  );
  const hostAlias = argValue(argv, '--host-alias') ?? defaultGateway();
  if (!hostAlias) {
    throw new Error('could not determine the host gateway (--host-alias)');
  }
  const listen =
    argValue(argv, '--listen') ??
    (role === 'ssh-agent'
      ? `unix:${GUEST_AGENT_SOCKET}`
      : `unix:${join(HOME, '.docker', 'run', 'docker.sock')}`);
  const forward = argValue(argv, '--forward') ?? `tcp:${hostAlias}:${port}`;
  return runBridge({
    listen: parseEndpoint(listen),
    forward: parseEndpoint(forward),
    log: (message) => process.stderr.write(`${message}\n`),
  });
}

async function status(): Promise<number> {
  const agentUp = await canConnect(parseEndpoint(`unix:${GUEST_AGENT_SOCKET}`));
  const dockerUp = await canConnect(
    parseEndpoint(`unix:${join(HOME, '.docker', 'run', 'docker.sock')}`),
  );
  process.stdout.write(`bridge-status:ssh-agent=${agentUp ? 'up' : 'down'}\n`);
  process.stdout.write(`bridge-status:docker=${dockerUp ? 'up' : 'down'}\n`);
  return 0;
}

function rulesCommand(argv: string[]): number {
  const content = readFileSync(0, 'utf8');
  if (argv.includes('--force')) {
    applyRules(HOME, content);
    process.stdout.write('rules:overwritten\n');
  } else {
    process.stdout.write(`rules:probe=${rulesAction(HOME, content)}\n`);
  }
  return 0;
}

function uninstall(): number {
  const uid = execFileSync('id', ['-u'], { encoding: 'utf8' }).trim();
  for (const label of Object.values(LAUNCHD_LABELS)) {
    try {
      execFileSync('launchctl', ['bootout', `gui/${uid}/${label}`], { stdio: 'ignore' });
    } catch {
      // not loaded — nothing to unload
    }
    rmSync(join(LAUNCH_AGENTS_DIR, `${label}.plist`), { force: true });
  }
  const zprofile = join(HOME, '.zprofile');
  const config = join(HOME, '.ssh', 'config');
  writeFileSync(zprofile, cleanupFile(readMaybe(zprofile)));
  writeFileSync(config, cleanupFile(readMaybe(config)));
  process.stdout.write('uninstalled:ssh-agent,docker\n');
  return 0;
}

function cleanupFile(content: string): string {
  let out = removeBlock(content, ZPROFILE_MARKERS.agent);
  out = removeBlock(out, ZPROFILE_MARKERS.env);
  out = removeBlock(out, '# SSH agent bridge to the host (see docs/ssh-agent.md)');
  return out.replace(/\n{3,}/g, '\n\n');
}

function readMaybe(path: string): string {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return '';
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  void main(process.argv.slice(2)).then((code) => {
    process.exit(code);
  });
}
