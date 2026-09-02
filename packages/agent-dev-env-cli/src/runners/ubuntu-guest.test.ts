import { describe, expect, it } from 'vitest';
import { guestCredentials, parseGuestStatus } from './ubuntu-guest.js';

const VARS = {
  ssh_username: 'admin',
  ssh_password: 'sandbox1',
  image_version: '1.1.0',
} as const;

describe('guestCredentials', () => {
  it('reads the user and password from the vars file', () => {
    expect(guestCredentials(VARS, {}, '192.168.64.10')).toEqual({
      host: '192.168.64.10',
      port: 22,
      username: 'admin',
      password: 'sandbox1',
    });
  });

  it('UBUNTU_PASSWORD overrides the vars-file password', () => {
    const creds = guestCredentials(VARS, { UBUNTU_PASSWORD: 'changed' }, '192.168.64.10');
    expect(creds.password).toBe('changed');
  });

  it('falls back to the admin user when the vars file has none', () => {
    const creds = guestCredentials({ ssh_password: 'sandbox1' }, {}, '192.168.64.10');
    expect(creds.username).toBe('admin');
    expect(creds.password).toBe('sandbox1');
  });

  it('throws when no ssh_password is available anywhere', () => {
    expect(() => guestCredentials({}, {}, '192.168.64.10')).toThrow(/ssh_password/);
  });
});

describe('parseGuestStatus', () => {
  it('parses both bridge-status lines', () => {
    const output = 'bridge-status:ssh-agent=up\nbridge-status:docker=down\n';
    expect(parseGuestStatus(output)).toEqual({ sshAgent: true, docker: false });
  });

  it('reports only the lines that are present', () => {
    expect(parseGuestStatus('bridge-status:ssh-agent=up\n')).toEqual({ sshAgent: true });
    expect(parseGuestStatus('everything else')).toEqual({});
  });
});
