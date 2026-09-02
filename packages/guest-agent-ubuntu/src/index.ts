// index.ts — guest-agent-ubuntu CLI. Runs inside the Ubuntu 24.04 sandbox
// guest (bundled single-file, node-only): installs/bridges the host SSH
// agent and Docker engine into the guest (systemd user units) and manages
// the agent rules.
//
//   guest-agent-ubuntu install [--agent-port N] [--docker-port N] [--host-alias A]
//   guest-agent-ubuntu bridge <ssh-agent|docker> [--listen EP] [--forward EP] [--port N]
//   guest-agent-ubuntu status
//   guest-agent-ubuntu rules [--force]
//   guest-agent-ubuntu uninstall
//
// The /etc/profile.d env script needs root: run `install` once through
// sudo (`sudo -S node guest-agent-ubuntu.js install …`) or the agent
// writes the user-level exports to ~/.profile instead and reports the
// difference.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runBridge } from 'bridge-core';
import { parseEndpoint } from 'bridge-core/endpoints';
import { canConnect } from 'bridge-core/probe';
import { applyRules, rulesAction } from 'guest-rules';
import {
  PROFILE_D_PATH,
  profileDScript,
  systemdUnit,
  UBUNTU_SOCKETS,
  type SystemdBridge,
} from './systemd.js';

const AGENT_PATH = fileURLToPath(import.meta.url);
const NODE_PATH = process.execPath;
const HOME = homedir();
const UNIT_DIR = join(HOME, '.config', 'systemd', 'user');

const DEFAULTS = {
  agentPort: 4400,
  dockerPort: 4401,
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
    process.stderr.write(`guest-agent-ubuntu: ${(err as Error).message}\n`);
    return 1;
  }
}

function usage(): string {
  return [
    'usage: guest-agent-ubuntu <install|bridge|status|rules|uninstall> [options]',
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

function bridgeFor(role: 'ssh-agent' | 'docker', port: number, hostAlias: string): SystemdBridge {
  return {
    unitName: `agent-sandbox-${role}.service`,
    description:
      role === 'ssh-agent' ? 'Agent Sandbox SSH agent bridge' : 'Agent Sandbox Docker bridge',
    nodePath: NODE_PATH,
    agentPath: AGENT_PATH,
    role,
    port,
    hostAlias,
    socket: UBUNTU_SOCKETS[role],
  };
}

function install(argv: string[]): number {
  const hostAlias =
    argValue(argv, '--host-alias') ??
    (() => {
      throw new Error('--host-alias is required (the NAT router address)');
    })();
  const agentPort = Number(argValue(argv, '--agent-port') ?? DEFAULTS.agentPort);
  const dockerPort = Number(argValue(argv, '--docker-port') ?? DEFAULTS.dockerPort);

  mkdirSync(UNIT_DIR, { recursive: true });
  for (const [role, port] of [
    ['ssh-agent', agentPort],
    ['docker', dockerPort],
  ] as const) {
    const bridge = bridgeFor(role, port, hostAlias);
    writeFileSync(join(UNIT_DIR, bridge.unitName), systemdUnit(bridge));
    process.stdout.write(`installed:${role} (${bridge.unitName}, port ${port})\n`);
  }
  execFileSync('systemctl', ['--user', 'daemon-reload'], { stdio: 'ignore' });
  for (const [role] of [['ssh-agent'], ['docker']] as const) {
    execFileSync('systemctl', ['--user', 'enable', '--now', `agent-sandbox-${role}.service`], {
      stdio: 'ignore',
    });
  }

  installProfileExports(hostAlias);
  return 0;
}

/** /etc/profile.d when root; otherwise the user's ~/.profile (report). */
function installProfileExports(gw: string): void {
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    writeFileSync(PROFILE_D_PATH, profileDScript(gw));
    process.stdout.write(`installed:profile.d (${PROFILE_D_PATH})\n`);
    return;
  }
  const profile = join(HOME, '.profile');
  const content = readMaybe(profile);
  if (!content.includes(profileMarker())) {
    writeFileSync(profile, `${content}${profileDScript(gw)}`);
  }
  process.stdout.write(
    `installed:profile.d (user ~/.profile; run install via sudo for ${PROFILE_D_PATH})\n`,
  );
}

function profileMarker(): string {
  return '# Agent sandbox bridge env';
}

function bridgeCommand(argv: string[]): Promise<number> {
  const role = argv[0];
  if (role !== 'ssh-agent' && role !== 'docker') {
    throw new Error(`unknown bridge role '${role}' (ssh-agent|docker)`);
  }
  const port = Number(
    argValue(argv, '--port') ?? DEFAULTS[role === 'ssh-agent' ? 'agentPort' : 'dockerPort'],
  );
  const hostAlias =
    argValue(argv, '--host-alias') ??
    (() => {
      throw new Error('--host-alias is required (the NAT router address)');
    })();
  const listen = argValue(argv, '--listen') ?? `unix:${UBUNTU_SOCKETS[role]}`;
  const forward = argValue(argv, '--forward') ?? `tcp:${hostAlias}:${port}`;
  return runBridge({
    listen: parseEndpoint(listen),
    forward: parseEndpoint(forward),
    log: (message) => process.stderr.write(`${message}\n`),
  });
}

async function status(): Promise<number> {
  const agentUp = await canConnect(parseEndpoint(`unix:${UBUNTU_SOCKETS['ssh-agent']}`));
  const dockerUp = await canConnect(parseEndpoint(`unix:${UBUNTU_SOCKETS.docker}`));
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
  for (const role of ['ssh-agent', 'docker'] as const) {
    const unit = `agent-sandbox-${role}.service`;
    try {
      execFileSync('systemctl', ['--user', 'disable', '--now', unit], { stdio: 'ignore' });
    } catch {
      // not running/installed — nothing to stop
    }
    rmSync(join(UNIT_DIR, unit), { force: true });
  }
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    rmSync(PROFILE_D_PATH, { force: true });
  }
  const profile = join(HOME, '.profile');
  if (existsSync(profile)) {
    const cleaned = removeProfileBlock(readMaybe(profile));
    if (cleaned !== readMaybe(profile)) {
      writeFileSync(profile, cleaned);
    }
  }
  process.stdout.write('uninstalled:ssh-agent,docker\n');
  return 0;
}

/** Removes the marker-guarded env block (blank separator line through
 *  the block's trailing blank line) from ~/.profile. */
export function removeProfileBlock(content: string): string {
  const lines = content.split('\n');
  const markerIndex = lines.findIndex((line) => line.startsWith(profileMarker()));
  if (markerIndex === -1) {
    return content;
  }
  const blockStart =
    markerIndex > 0 && lines[markerIndex - 1] === '' ? markerIndex - 1 : markerIndex;
  let blockEnd = markerIndex + 1;
  while (blockEnd < lines.length && lines[blockEnd] !== '') {
    blockEnd += 1;
  }
  if (blockEnd < lines.length) {
    blockEnd += 1; // the block's trailing blank line
  }
  return [...lines.slice(0, blockStart), ...lines.slice(blockEnd)]
    .join('\n')
    .replace(/\n{3,}/g, '\n\n');
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
