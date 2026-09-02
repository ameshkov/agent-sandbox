import { describe, expect, it } from 'vitest';
import { encodePsCommand, guestCredentials, stripSentinel } from './windows-guest.js';

const VARS = {
  winrm_username: 'Administrator',
  winrm_password: 'sandbox1',
  image_version: '1.0.0',
} as const;

describe('guestCredentials', () => {
  it('reads the user and password from the vars file', () => {
    expect(guestCredentials(VARS, {}, '192.168.64.10')).toEqual({
      host: '192.168.64.10',
      port: 22,
      username: 'Administrator',
      password: 'sandbox1',
    });
  });

  it('WINDOWS_PASSWORD overrides the vars-file password', () => {
    const creds = guestCredentials(VARS, { WINDOWS_PASSWORD: 'changed' }, '192.168.64.10');
    expect(creds.password).toBe('changed');
  });

  it('targets the forwarded ssh port when given (QEMU hostfwd)', () => {
    const creds = guestCredentials(VARS, {}, '127.0.0.1', 2222);
    expect(creds.host).toBe('127.0.0.1');
    expect(creds.port).toBe(2222);
  });

  it('falls back to the Administrator user when the vars file has none', () => {
    const creds = guestCredentials({ winrm_password: 'sandbox1' }, {}, '192.168.64.10');
    expect(creds.username).toBe('Administrator');
    expect(creds.password).toBe('sandbox1');
  });

  it('throws when no winrm_password is available anywhere', () => {
    expect(() => guestCredentials({}, {}, '192.168.64.10')).toThrow(/winrm_password/);
  });
});

describe('stripSentinel', () => {
  it('keeps the output before the completion sentinel', () => {
    expect(stripSentinel('bridge-status:ssh-agent=up\nade-abc123\ntrickle\n', 'ade-abc123')).toBe(
      'bridge-status:ssh-agent=up\n',
    );
  });

  it('returns the output untouched when the sentinel is missing', () => {
    expect(stripSentinel('bridge-status:docker=down\n', 'ade-abc123')).toBe(
      'bridge-status:docker=down\n',
    );
  });
});

describe('encodePsCommand', () => {
  it('encodes the script as UTF-16LE base64 (the -EncodedCommand format)', () => {
    const b64 = encodePsCommand("Write-Output 'hi'");
    expect(Buffer.from(b64, 'base64').toString('utf16le')).toBe("Write-Output 'hi'");
  });

  it('never emits a byte-order mark (always LE)', () => {
    const bytes = Buffer.from(encodePsCommand('ab'), 'base64');
    // no BOM (0xFF 0xFE) ahead of the little-endian 'a','b'.
    expect([...bytes.subarray(0, 4)]).toEqual([0x61, 0x00, 0x62, 0x00]);
  });
});
