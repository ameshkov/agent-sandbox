// runners/windows-summary.ts — the Windows VMware "Sandbox is ready" block
// (port of the shell's print_summary in run-windows-vmware-sandbox.sh:
// same labels, same wording, same color scheme — with the CLI's 12-char
// label column, like the other summaries).

import { existsSync } from 'node:fs';
import { logger } from '../lib/logger.js';
import { imageRootDir, workingVmxPath } from '../lib/paths.js';
import { PLATFORM_DEFAULTS } from '../lib/platform.js';
import type { RunContext, RunState } from './framework.js';
import { resolveGuestCredentials } from './windows-guest.js';

/** Prints the Windows summary block (image/VM/IP/SSH/RDP/WinRM/shared
 *  dir/bridges/OpenChamber/state/stop hints).
 *
 * @param context - The run context.
 * @param state - The accumulated run state.
 */
export async function printWindowsSummary(context: RunContext, state: RunState): Promise<void> {
  const workVmx = workingVmxPath(context.platform, context.image);
  const stateDir = imageRootDir(context.platform, context.image);
  const defs = PLATFORM_DEFAULTS['windows-vmware'];
  const creds = state.vmIp
    ? resolveGuestCredentials(context.image, context.options.env, state.vmIp)
    : undefined;

  logger.step('Sandbox is ready');
  summaryLine('Image:', state.imageArchive ?? 'not available');
  summaryLine('VM:', workVmx);
  summaryLine('Guest IP:', state.vmIp ? `${state.vmIp} (Fusion NAT, vmnet8)` : 'unavailable');
  summaryLine(
    'SSH:',
    `ssh ${creds?.username ?? 'Administrator'}@${state.vmIp ?? '?'} (password: ${creds?.password ?? 'sandbox1'})`,
  );
  summaryLine(
    'RDP:',
    `${state.vmIp ?? '?'}:${defs.rdpPort ?? 3389} (${creds?.username ?? 'Administrator'} / ${creds?.password ?? 'sandbox1'})`,
  );
  summaryLine('WinRM:', `${state.vmIp ?? '?'}:${defs.winrmPort ?? 5985} (advanced use)`);
  printSharedLine(context, state);
  printBridgeLines(context, state);
  printOpenchamberLine(context, state);
  summaryLine('State:', `${stateDir} (extracted base + working clone; --reset re-clones)`);
  printStopLines(context, state, workVmx);
}

/** One `    LABEL........  VALUE` line. */
function summaryLine(label: string, value: string): void {
  logger.out(`    ${label.padEnd(12)}${value}`);
}

function printSharedLine(context: RunContext, state: RunState): void {
  if (state.sharedFolderSkipped) {
    summaryLine(
      'Shared:',
      loggerWarn(
        'not supported (Windows 11 ARM guest on Apple silicon — no HGFS driver in VMware Tools)',
      ),
    );
    return;
  }
  if (context.workDir && existsSync(context.workDir)) {
    summaryLine('Shared:', `\\\\vmware-host\\Shared Folders\\work -> ${context.workDir}`);
  } else {
    summaryLine('Shared:', 'not shared');
  }
}

function printBridgeLines(context: RunContext, state: RunState): void {
  const agent = state.bridges.agent;
  if (agent.bridged) {
    const value = agent.guestUp
      ? `host agent -> TCP ${context.agentPort} -> guest \\\\.\\pipe\\openssh-ssh-agent`
      : `host bridge up (TCP ${context.agentPort}), guest pipe not running`;
    summaryLine('SSH agent:', agent.guestUp ? loggerOk(value) : loggerWarn(value));
  } else {
    summaryLine('SSH agent:', 'not bridged');
  }
  const docker = state.bridges.docker;
  if (docker.bridged) {
    if (docker.engineUp) {
      summaryLine(
        'Docker:',
        loggerOk(
          `host engine (v${docker.serverVersion}) -> TCP ${context.dockerPort} -> guest (context 'host')`,
        ),
      );
    } else if (docker.guestUp) {
      summaryLine(
        'Docker:',
        loggerWarn('bridge up, engine not reachable in the guest — is Docker running on the host?'),
      );
    } else {
      summaryLine(
        'Docker:',
        loggerWarn(`host bridge up (TCP ${context.dockerPort}), guest pipe not running`),
      );
    }
  } else {
    summaryLine('Docker:', 'not bridged');
  }
}

function printOpenchamberLine(context: RunContext, state: RunState): void {
  if (state.openchamberUp && state.openchamberUrl) {
    summaryLine('OpenChamber:', loggerOk(`${state.openchamberUrl} (password: sandbox)`));
  } else {
    summaryLine(
      'OpenChamber:',
      loggerWarn(`not responding on http://${state.vmIp ?? '?'}:${context.openchamberPort}`),
    );
  }
}

function printStopLines(context: RunContext, state: RunState, workVmx: string): void {
  summaryLine(
    'Stop:',
    `run "agent-dev-env stop windows-vmware" (or: vmrun -T fusion stop '${workVmx}')`,
  );
  if (!context.options.foreground) {
    if (state.bridges.agent.bridged) {
      summaryLine(
        'Bridge:',
        `host listener on TCP ${context.agentPort} stays up — stop it with: agent-dev-env stop windows-vmware`,
      );
    }
    if (state.bridges.docker.bridged) {
      summaryLine(
        'Bridge:',
        `host Docker listener on TCP ${context.dockerPort} stays up — stop it with: agent-dev-env stop windows-vmware`,
      );
    }
  }
}

// color helpers — the shell's ${c_green}/${c_yellow} inline.
function loggerOk(text: string): string {
  return logger.color('green') + text + logger.reset();
}

function loggerWarn(text: string): string {
  return logger.color('yellow') + text + logger.reset();
}
