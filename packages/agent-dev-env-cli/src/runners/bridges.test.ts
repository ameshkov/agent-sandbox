import { createServer, type Server } from 'node:net';
import { mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { canConnectTcp, findHostAgentSocket, findHostDockerSocket } from './bridges.js';

let server: Server | undefined;

afterEach(async () => {
  if (server) {
    await new Promise<void>((resolve) => server?.close(() => resolve()));
    server = undefined;
  }
});

describe('findHostAgentSocket', () => {
  it('returns nothing for an unset or stock macOS agent socket', () => {
    expect(findHostAgentSocket({}, '/Users/test')).toBeUndefined();
    expect(
      findHostAgentSocket(
        { SSH_AUTH_SOCK: '/var/run/com.apple.launchd.abc123/Listeners' },
        '/Users/test',
      ),
    ).toBeUndefined();
  });

  it('returns the socket when SSH_AUTH_SOCK points at one', () => {
    const dir = mkdtempSync(join(tmpdir(), 'agent-sock-'));
    const sock = join(dir, 'agent.sock');
    const listener = createServer();
    listener.listen(sock);
    server = listener;
    expect(findHostAgentSocket({ SSH_AUTH_SOCK: sock }, '/Users/test')).toBe(sock);
  });

  it('treats a non-existent SSH_AUTH_SOCK as no bridge', () => {
    expect(
      findHostAgentSocket({ SSH_AUTH_SOCK: '/tmp/does-not-exist.sock' }, '/Users/test'),
    ).toBeUndefined();
  });
});

describe('findHostDockerSocket', () => {
  it('finds a Docker Desktop socket first', () => {
    const home = mkdtempSync(join(tmpdir(), 'agent-docker-'));
    const dir = join(home, '.docker', 'run');
    mkdirSync(dir, { recursive: true });
    const sock = join(dir, 'docker.sock');
    const listener = createServer();
    listener.listen(sock);
    server = listener;
    expect(findHostDockerSocket(home)).toBe(sock);
  });

  it('returns nothing when no engine socket exists', () => {
    const home = mkdtempSync(join(tmpdir(), 'agent-empty-'));
    expect(findHostDockerSocket(home)).toBeUndefined();
  });
});

describe('canConnectTcp', () => {
  it('resolves true when the port accepts a connection', async () => {
    const listener = createServer(() => {
      // accept-and-drop — the probe just needs a connection
    });
    await new Promise<void>((resolve) => listener.listen(0, '127.0.0.1', resolve));
    server = listener;
    const address = listener.address();
    if (!address || typeof address === 'string') {
      throw new Error('no address');
    }
    await expect(canConnectTcp('127.0.0.1', address.port)).resolves.toBe(true);
  });

  it('resolves false when the port is closed', async () => {
    const listener = createServer();
    await new Promise<void>((resolve) => listener.listen(0, '127.0.0.1', resolve));
    const address = listener.address();
    if (!address || typeof address === 'string') {
      throw new Error('no address');
    }
    const port = address.port;
    await new Promise<void>((resolve) => listener.close(() => resolve()));
    await expect(canConnectTcp('127.0.0.1', port)).resolves.toBe(false);
  });
});
