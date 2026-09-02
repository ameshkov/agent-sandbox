import { describe, expect, it } from 'vitest';
import {
  dockerContextCommands,
  relayStartCommand,
  schtasksXml,
  userEnvCommand,
  WINDOWS_PIPES,
  WINDOWS_TASK_NAMES,
} from './schtasks.js';

describe('schtasks builders (windows)', () => {
  it('WINDOWS_PIPES maps roles to the named pipes', () => {
    expect(WINDOWS_PIPES['ssh-agent']).toBe('\\\\.\\pipe\\openssh-ssh-agent');
    expect(WINDOWS_PIPES.docker).toBe('\\\\.\\pipe\\docker_engine');
  });

  it('schtasksXml registers an ONLOGON task running the bridge on the pipe', () => {
    const xml = schtasksXml({
      taskName: WINDOWS_TASK_NAMES['ssh-agent'],
      description: 'Agent Sandbox SSH agent bridge',
      nodePath: 'C:\\Program Files\\nodejs\\node.exe',
      agentPath: 'C:\\tools\\agent-dev-env\\guest-agent-windows.js',
      role: 'ssh-agent',
      pipe: WINDOWS_PIPES['ssh-agent'],
      port: 4300,
      hostAlias: '192.168.64.1',
    });
    expect(xml).toContain('<LogonTrigger>');
    expect(xml).toContain('<Command>C:\\Program Files\\nodejs\\node.exe</Command>');
    expect(xml).toContain('--host-alias 192.168.64.1');
    expect(xml).toContain('--listen pipe:');
    expect(xml).toContain('\\\\.\\pipe\\openssh-ssh-agent');
    expect(xml).toContain('--forward tcp:192.168.64.1:4300');
  });

  it('userEnvCommand builds the PowerShell statement', () => {
    expect(userEnvCommand('SSH_AUTH_SOCK', '\\\\.\\pipe\\openssh-ssh-agent')).toBe(
      "[Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK','\\\\.\\pipe\\openssh-ssh-agent','User')",
    );
  });

  it('dockerContextCommands wire the npipe endpoint', () => {
    const commands = dockerContextCommands();
    expect(commands).toHaveLength(3);
    expect(commands[0]).toContain('host=npipe:////./pipe/docker_engine');
    expect(commands[2]).toBe('docker context use host');
  });

  it('relayStartCommand builds a detached .cmd starting both relays', () => {
    const cmd = relayStartCommand(
      'C:\\Program Files\\nodejs\\node.exe',
      'C:\\tools\\agent-dev-env\\guest-agent-windows.js',
      [
        {
          role: 'ssh-agent',
          pipe: WINDOWS_PIPES['ssh-agent'],
          port: 4300,
          hostAlias: '192.168.64.1',
        },
        { role: 'docker', pipe: WINDOWS_PIPES.docker, port: 4301, hostAlias: '192.168.64.1' },
      ],
    );
    expect(cmd).toContain('@echo off');
    expect(cmd).toContain('"C:\\Program Files\\nodejs\\node.exe"');
    expect(cmd).toContain('bridge ssh-agent --port 4300');
    expect(cmd).toContain('bridge docker --port 4301');
    expect(cmd).toContain('--listen pipe:\\\\.\\pipe\\docker_engine');
    expect(cmd).toContain('--forward tcp:192.168.64.1:4300');
  });

  it('WINDOWS_TASK_NAMES includes the relay system task', () => {
    expect(WINDOWS_TASK_NAMES.relays).toBe('agent-sandbox-relays');
  });
});
