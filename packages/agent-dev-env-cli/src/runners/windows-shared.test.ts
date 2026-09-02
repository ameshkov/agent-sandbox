import { describe, expect, it } from 'vitest';
import { hgfsUnsupported } from './windows-shared.js';

describe('hgfsUnsupported', () => {
  it('detects an ARM Windows guest from the vmx guestos line', () => {
    const vmx = 'guestos = "arm-windows11-64"\n';
    expect(hgfsUnsupported(vmx)).toBe(true);
  });

  it('does not flag x64 or non-Windows guests', () => {
    expect(hgfsUnsupported('guestos = "windows11-64"\n')).toBe(false);
    expect(hgfsUnsupported('guestos = "ubuntu-64"\n')).toBe(false);
  });

  it('ignores indentation and case-insensitive key spellings', () => {
    expect(hgfsUnsupported('  guestos = "arm-windows11-64"\n')).toBe(true);
    expect(hgfsUnsupported('GuestOS = "arm-windows11-64"\n')).toBe(false);
  });

  it('returns false when no guestos line is present', () => {
    expect(hgfsUnsupported('scsi0:0.fileName = "disk.vmdk"\n')).toBe(false);
  });
});
