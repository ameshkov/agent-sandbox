// runners/options.ts — `run` option resolution: commander flags merged over
// the SANDBOX_* environment variables onto the platform defaults (the same
// precedence chain the shell runners had: env holds the defaults, flags
// override them). Pure + unit-tested; the command layer just builds this.

import { homedir } from 'node:os';
import { PLATFORM_DEFAULTS, type Platform } from '../lib/platform.js';

/** The raw `run` command flags (from commander). */
export interface RunFlags {
  headless?: boolean;
  foreground?: boolean;
  noAgent?: boolean;
  noDocker?: boolean;
  noSettings?: boolean;
  reset?: boolean;
  yes?: boolean;
  workDir?: string;
  image?: string;
  owner?: string;
}

/** Everything the runner needs, resolved (flags > env > defaults). */
export interface RunOptions {
  platform: Platform;
  image: string;
  vm: string;
  workDir: string;
  mountName: string;
  agentPort: number;
  dockerPort: number;
  openchamberPort: number;
  /** Host port forwarded to guest SSH 22 (windows-qemu; 22 elsewhere). */
  sshPort: number;
  /** Host port forwarded to guest RDP 3389 (windows-qemu). */
  rdpPort: number;
  /** Host port forwarded to guest WinRM 5985 (windows-qemu). */
  winrmPort: number;
  cpuCount: number;
  memoryMb: number;
  headless: boolean;
  foreground: boolean;
  noAgent: boolean;
  noDocker: boolean;
  noSettings: boolean;
  reset: boolean;
  yes: boolean;
  owner?: string;
  /** Env used for resolution (tests inject a fixture). */
  env: Record<string, string | undefined>;
  /** Host home dir (settings/socket discovery). */
  home: string;
}

/** @internal — port env override validation (1-65535). */
export function parsePortEnv(value: string, name: string): number {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`invalid ${name} port: ${value} (expected 1-65535)`);
  }
  return port;
}

function parseIntEnv(value: string, name: string, def: number): number {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : def;
}

/** Resolves the run options for a platform from flags + env.
 *
 * @param platform - The target platform.
 * @param flags - Overrides from the CLI flags.
 * @param env - Environment (defaults to process.env).
 * @param home - Host home directory (defaults to os.homedir()).
 * @returns The resolved options.
 * @throws Error on an invalid port override.
 */
export function resolveRunOptions(
  platform: Platform,
  flags: RunFlags = {},
  env: Record<string, string | undefined> = process.env,
  home: string = homedir(),
): RunOptions {
  const defs = PLATFORM_DEFAULTS[platform];
  const workDirFlag = flags.workDir !== undefined ? flags.workDir : env.SANDBOX_WORK_DIR;
  return {
    platform,
    image: flags.image ?? env.SANDBOX_IMAGE ?? defs.image,
    vm: env.SANDBOX_VM ?? defs.vmName,
    workDir: workDirFlag ?? defs.workDir ?? '',
    mountName: env.SANDBOX_MOUNT_NAME ?? defs.mountName ?? 'dev',
    agentPort: parsePortEnv(env.SANDBOX_AGENT_PORT ?? String(defs.agentPort), 'SANDBOX_AGENT_PORT'),
    dockerPort: parsePortEnv(
      env.SANDBOX_DOCKER_PORT ?? String(defs.dockerPort),
      'SANDBOX_DOCKER_PORT',
    ),
    openchamberPort: parsePortEnv(
      env.SANDBOX_OPENCHAMBER_PORT ?? String(defs.openchamberPort),
      'SANDBOX_OPENCHAMBER_PORT',
    ),
    sshPort: parsePortEnv(env.SANDBOX_SSH_PORT ?? String(defs.sshPort ?? 22), 'SANDBOX_SSH_PORT'),
    rdpPort: parsePortEnv(env.SANDBOX_RDP_PORT ?? String(defs.rdpPort ?? 3389), 'SANDBOX_RDP_PORT'),
    winrmPort: parsePortEnv(
      env.SANDBOX_WINRM_PORT ?? String(defs.winrmPort ?? 5985),
      'SANDBOX_WINRM_PORT',
    ),
    cpuCount: parseIntEnv(env.SANDBOX_CPU_COUNT ?? '', 'SANDBOX_CPU_COUNT', defs.cpuCount),
    memoryMb: parseIntEnv(env.SANDBOX_MEMORY_MB ?? '', 'SANDBOX_MEMORY_MB', defs.memoryMb),
    headless: flags.headless === true,
    foreground: flags.foreground === true,
    noAgent: flags.noAgent === true,
    noDocker: flags.noDocker === true,
    noSettings: flags.noSettings === true,
    reset: flags.reset === true,
    yes: flags.yes === true,
    owner: flags.owner,
    env,
    home,
  };
}
