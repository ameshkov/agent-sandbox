import { describe, expect, it } from 'vitest';
import { parseBridgeArgs } from './index.js';

describe('parseBridgeArgs', () => {
  it('parses --listen, --forward and --pidfile', () => {
    const args = parseBridgeArgs([
      '--listen',
      'unix:/tmp/agent.sock',
      '--forward',
      'tcp:192.168.64.1:4100',
      '--pidfile',
      '/tmp/bridge.pid',
    ]);
    expect(args.listen).toEqual({ kind: 'unix', path: '/tmp/agent.sock' });
    expect(args.forward).toEqual({ kind: 'tcp', host: '192.168.64.1', port: 4100 });
    expect(args.pidfile).toBe('/tmp/bridge.pid');
  });

  it('makes --pidfile optional', () => {
    const args = parseBridgeArgs([
      '--listen',
      'pipe:docker_engine',
      '--forward',
      'tcp:10.0.2.2:4201',
    ]);
    expect(args.pidfile).toBeUndefined();
  });

  it('throws when a required flag is missing or unknown', () => {
    expect(() => parseBridgeArgs(['--listen', 'unix:/x'])).toThrow(/usage/);
    expect(() =>
      parseBridgeArgs(['--listen', 'unix:/x', '--forward', 'unix:/y', '--wat', '1']),
    ).toThrow(/unknown argument/);
  });
});
