// schtasks.ts — pure builders for the Windows guest agent's artifacts:
// the scheduled-task XML that runs each bridge at logon, and the
// PowerShell command lines for the user env var + docker context.

export interface WindowsTask {
  taskName: string; // e.g. agent-sandbox-ssh-agent
  description: string;
  nodePath: string; // C:\Program Files\nodejs\node.exe
  agentPath: string; // C:\tools\agent-dev-env\guest-agent-windows.js
  /** bridge role: ssh-agent | docker. */
  role: string;
  pipe: string; // \\.\pipe\openssh-ssh-agent
  port: number;
  hostAlias: string; // x.y.z.1 (NAT) or 10.0.2.2 (QEMU)
}

export const WINDOWS_PIPES = {
  'ssh-agent': '\\\\.\\pipe\\openssh-ssh-agent',
  docker: '\\\\.\\pipe\\docker_engine',
} as const;

export const WINDOWS_TASK_NAMES = {
  'ssh-agent': 'agent-sandbox-ssh-agent',
  docker: 'agent-sandbox-docker',
  /** the SYSTEM ONCE task that starts both relays right after install. */
  relays: 'agent-sandbox-relays',
} as const;

const DOCKER_CONTEXT = 'host';

/** The Task XML registered with `schtasks /Create /XML` (UTF-16). */
export function schtasksXml(task: WindowsTask): string {
  const args = [
    'bridge',
    task.role,
    '--port',
    String(task.port),
    '--host-alias',
    task.hostAlias,
    '--listen',
    `pipe:${task.pipe}`,
    '--forward',
    `tcp:${task.hostAlias}:${task.port}`,
  ].join(' ');
  return [
    '<?xml version="1.0" encoding="UTF-16"?>',
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">',
    '  <RegistrationInfo>',
    `    <Description>${escapeXml(task.description)}</Description>`,
    '    <Author>agent-dev-env</Author>',
    '  </RegistrationInfo>',
    '  <Triggers>',
    '    <LogonTrigger>',
    '      <Enabled>true</Enabled>',
    '    </LogonTrigger>',
    '  </Triggers>',
    '  <Principals>',
    '    <Principal id="Author">',
    '      <LogonType>InteractiveToken</LogonType>',
    '      <RunLevel>LeastPrivilege</RunLevel>',
    '    </Principal>',
    '  </Principals>',
    '  <Settings>',
    '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
    '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
    '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>',
    '    <StartWhenAvailable>true</StartWhenAvailable>',
    '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>',
    '    <Enabled>true</Enabled>',
    '  </Settings>',
    '  <Actions Context="Author">',
    '    <Exec>',
    `      <Command>${escapeXml(task.nodePath)}</Command>`,
    `      <Arguments>${escapeXml(`"${task.agentPath}" ${args}`)}</Arguments>`,
    '    </Exec>',
    '  </Actions>',
    '</Task>',
    '',
  ].join('\n');
}

/** The PowerShell -Command string setting a user env var. */
export function userEnvCommand(name: string, value: string): string {
  return `[Environment]::SetEnvironmentVariable('${name}','${value}','User')`;
}

/** PowerShell command lines for the docker context 'host' → npipe. */
export function dockerContextCommands(): string[] {
  const endpoint = `npipe:////./pipe/docker_engine`;
  return [
    `docker context create ${DOCKER_CONTEXT} --docker "host=${endpoint}"`,
    `docker context update ${DOCKER_CONTEXT} --docker "host=${endpoint}"`,
    `docker context use ${DOCKER_CONTEXT}`,
  ];
}

/** The start-relays.cmd the install writes next to the agent: detached
 *  starter for both bridge relays (the SYSTEM ONCE task's action). The
 *  listed task fields mirror the ONLOGON tasks' bridge args, so the
 *  manual start and the logon persistence run the same commands.
 *
 * @param nodePath - The node binary (the agent's own execPath).
 * @param agentPath - The absolute guest-agent path.
 * @param tasks - The bridge tasks to start (ssh-agent + docker).
 * @returns The .cmd content (ASCII).
 */
export function relayStartCommand(
  nodePath: string,
  agentPath: string,
  tasks: ReadonlyArray<Pick<WindowsTask, 'role' | 'pipe' | 'port' | 'hostAlias'>>,
): string {
  const lines = ['@echo off'];
  for (const task of tasks) {
    lines.push(
      `start "" /b "${nodePath}" "${agentPath}" bridge ${task.role} ` +
        `--port ${task.port} --host-alias ${task.hostAlias} ` +
        `--listen pipe:${task.pipe} --forward tcp:${task.hostAlias}:${task.port}`,
    );
  }
  return lines.join('\r\n') + '\r\n';
}

function escapeXml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}
