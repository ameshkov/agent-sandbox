// runners/windows-qemu-summary.ts — the Windows QEMU "Sandbox is ready"
// block (port of the shell's print_summary in
// run-windows-qemu-sandbox.sh: same labels, same wording, same color
// scheme — with the CLI's 12-char label column, like the other
// summaries). The QEMU guest is reached through the hostfwd forwards on
// 127.0.0.1, unlike the VMware backends' direct guest-IP lines.

import { logger } from '../lib/logger.js';
import { qemuLogPath, qemuPidFile, qemuStateDir } from '../lib/qemu.js';
import type { RunContext, RunState } from './framework.js';
import { resolveGuestCredentials } from './windows-guest.js';

/** Prints the QEMU Windows summary block (image/SSH/RDP/WinRM/bridges/
 *  OpenChamber/state/stop hints).
 *
 * @param context - The run context.
 * @param state - The accumulated run state.
 */
export async function printQemuSummary(context: RunContext, state: RunState): Promise<void> {
  const creds = resolveGuestCredentials(
    context.image,
    context.options.env,
    '127.0.0.1',
    context.sshPort,
  );

  logger.step('Sandbox is ready');
  summaryLine('Image:', state.imageArchive ?? 'not available');
  summaryLine(
    'SSH:',
    `ssh -p ${context.sshPort} ${creds.username}@127.0.0.1 (password: ${creds.password})`,
  );
  summaryLine('RDP:', `127.0.0.1:${context.rdpPort} (${creds.username} / ${creds.password})`);
  summaryLine('WinRM:', `127.0.0.1:${context.winrmPort} (advanced use)`);
  printBridgeLines(context, state);
  printOpenchamberLine(context, state);
  summaryLine(
    'State:',
    `${qemuStateDir(context.image)} (overlay + TPM + EFI NVRAM; --reset wipes it)`,
  );
  printStopLines(context, state);
}

/** One `    LABEL........  VALUE` line. */
function summaryLine(label: string, value: string): void {
  logger.out(`    ${label.padEnd(12)}${value}`);
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
      loggerWarn(`not responding on http://127.0.0.1:${context.openchamberPort}`),
    );
  }
}

function printStopLines(context: RunContext, state: RunState): void {
  summaryLine(
    'Stop:',
    `agent-dev-env stop windows-qemu (or: kill $(cat ${qemuPidFile(context.image)}))`,
  );
  if (!context.options.foreground) {
    summaryLine(
      'Background:',
      `VM keeps running after this CLI exits (qemu log: ${qemuLogPath()})`,
    );
    if (state.bridges.agent.bridged) {
      summaryLine(
        'Bridge:',
        `host bridge on TCP ${context.agentPort} stays up — stop it with: agent-dev-env stop windows-qemu`,
      );
    }
    if (state.bridges.docker.bridged) {
      summaryLine(
        'Bridge:',
        `host Docker bridge on TCP ${context.dockerPort} stays up — stop it with: agent-dev-env stop windows-qemu`,
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
