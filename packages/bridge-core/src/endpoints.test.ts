import { describe, expect, it } from 'vitest';
import { formatEndpoint, parseEndpoint } from './endpoints.js';

describe('parseEndpoint', () => {
  it('parses unix endpoints', () => {
    expect(parseEndpoint('unix:/tmp/ssh-agent.sock')).toEqual({
      kind: 'unix',
      path: '/tmp/ssh-agent.sock',
    });
  });

  it('parses pipe endpoints and normalizes the short form', () => {
    expect(parseEndpoint('pipe:openssh-ssh-agent')).toEqual({
      kind: 'pipe',
      name: '\\\\.\\pipe\\openssh-ssh-agent',
    });
    expect(parseEndpoint('pipe:\\\\.\\pipe\\docker_engine')).toEqual({
      kind: 'pipe',
      name: '\\\\.\\pipe\\docker_engine',
    });
  });

  it('parses tcp endpoints', () => {
    expect(parseEndpoint('tcp:192.168.64.1:4100')).toEqual({
      kind: 'tcp',
      host: '192.168.64.1',
      port: 4100,
    });
  });

  it('rejects unknown schemes', () => {
    expect(() => parseEndpoint('socat:1:2')).toThrow(/unknown endpoint scheme/);
    expect(() => parseEndpoint('')).toThrow(/invalid endpoint/);
  });

  it('rejects malformed specs and out-of-range ports', () => {
    expect(() => parseEndpoint('tcp:host')).toThrow(/invalid tcp endpoint/);
    expect(() => parseEndpoint('tcp:host:0')).toThrow(/invalid tcp endpoint/);
    expect(() => parseEndpoint('tcp:host:70000')).toThrow(/invalid tcp endpoint/);
    expect(() => parseEndpoint('unix:')).toThrow(/missing path/);
    expect(() => parseEndpoint('pipe:')).toThrow(/missing name/);
  });

  it('formats endpoints back to their spec form', () => {
    expect(formatEndpoint(parseEndpoint('unix:/tmp/x.sock'))).toBe('unix:/tmp/x.sock');
    expect(formatEndpoint(parseEndpoint('tcp:127.0.0.1:4100'))).toBe('tcp:127.0.0.1:4100');
  });
});
