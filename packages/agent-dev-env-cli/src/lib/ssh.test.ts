import { describe, expect, it } from 'vitest';
import { sshProbeOutcome } from './ssh.js';

describe('sshProbeOutcome', () => {
  it('classifies an authentication failure as sshd being up', () => {
    expect(sshProbeOutcome('All configured authentication methods failed')).toBe('up');
    expect(sshProbeOutcome('Permission denied (publickey,password)')).toBe('up');
  });

  it('classifies a handshake error as sshd being up', () => {
    expect(sshProbeOutcome('Unable to negotiate a key exchange')).toBe('up');
  });

  it('classifies connect-level failures as sshd being down', () => {
    expect(sshProbeOutcome('connect ECONNREFUSED 192.168.64.10:22')).toBe('down');
    expect(sshProbeOutcome('connect ETIMEDOUT 192.168.64.10:22')).toBe('down');
    expect(sshProbeOutcome('connect ENETUNREACH 192.168.64.10:22')).toBe('down');
    expect(sshProbeOutcome('read ECONNRESET')).toBe('down');
  });

  it('returns unknown for anything else', () => {
    expect(sshProbeOutcome('something unexpected')).toBe('unknown');
  });
});
