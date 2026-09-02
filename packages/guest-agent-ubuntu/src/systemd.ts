// systemd.ts — pure builders for the Ubuntu guest agent's artifacts:
// systemd user units (the bridges) and the /etc/profile.d env script.

export interface SystemdBridge {
  unitName: string; // e.g. agent-sandbox-ssh-agent.service
  description: string;
  nodePath: string;
  agentPath: string;
  /** bridge role: ssh-agent | docker. */
  role: string;
  port: number;
  hostAlias: string;
  /** guest Unix socket the role listens on. */
  socket: string;
}

export const UBUNTU_SOCKETS = {
  'ssh-agent': '/tmp/ssh-agent.sock',
  docker: '/tmp/docker.sock',
} as const;

export const PROFILE_D_PATH = '/etc/profile.d/agent-sandbox.sh';

/** Builds a systemd user unit running `node agent bridge <role> …`. */
export function systemdUnit(bridge: SystemdBridge): string {
  const args = [
    'bridge',
    bridge.role,
    '--port',
    String(bridge.port),
    '--host-alias',
    bridge.hostAlias,
    '--listen',
    `unix:${bridge.socket}`,
    '--forward',
    `tcp:${bridge.hostAlias}:${bridge.port}`,
  ];
  return [
    '[Unit]',
    `Description=${bridge.description}`,
    'After=network.target',
    '',
    '[Service]',
    'Type=simple',
    `ExecStart=${bridge.nodePath} ${bridge.agentPath} ${args.join(' ')}`,
    'Restart=on-failure',
    '',
    '[Install]',
    'WantedBy=default.target',
    '',
  ].join('\n');
}

/** The /etc/profile.d script: bridge env exports for every login shell. */
export function profileDScript(gw: string): string {
  return [
    '# Agent sandbox bridge env (see docs/ubuntu-vmware.md)',
    'export SSH_AUTH_SOCK=/tmp/ssh-agent.sock',
    'export DOCKER_HOST=unix:///tmp/docker.sock',
    `export TESTCONTAINERS_HOST_OVERRIDE=${gw}`,
    '',
    '',
  ].join('\n');
}
