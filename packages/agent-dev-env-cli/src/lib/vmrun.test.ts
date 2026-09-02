import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  parseGuestIpAddress,
  parseToolsState,
  parseVmwareHwVersion,
  rewriteVmxDisplayName,
  sharedFolderAlreadyExists,
  vmwareHwVersion,
} from './vmrun.js';

describe('parseVmwareHwVersion', () => {
  it('reads the virtualhw.version from a vmx text', () => {
    const content = 'virtualhw.version = "20"\nmem.vmm\ttrue\n';
    expect(parseVmwareHwVersion(content)).toBe('20');
  });

  it('returns undefined when the key is missing', () => {
    expect(parseVmwareHwVersion('displayName = "x"\n')).toBeUndefined();
  });
});

describe('rewriteVmxDisplayName', () => {
  it('replaces the existing displayname line (case-insensitive)', () => {
    const content = 'displayName = "base"\nmem.vmm\ttrue\n';
    const rewritten = rewriteVmxDisplayName(content, 'working');
    expect(rewritten).toBe('displayname = "working"\nmem.vmm\ttrue\n');
  });

  it('appends the key when the vmx has none', () => {
    const content = 'mem.vmm\ttrue\n';
    expect(rewriteVmxDisplayName(content, 'working')).toBe(
      'mem.vmm\ttrue\ndisplayname = "working"\n',
    );
  });

  it('rewrites a lowercase key written by vmrun', () => {
    const content = 'displayname = "sandbox-ubuntu-24-04-arm64-vmware"\n';
    expect(rewriteVmxDisplayName(content, 'agent-sandbox')).toBe('displayname = "agent-sandbox"\n');
  });
});

describe('vmwareHwVersion', () => {
  it('reads the version from a real vmx file', () => {
    const dir = mkdtempSync(join(tmpdir(), 'vmrun-'));
    try {
      const vmx = join(dir, 'test.vmx');
      writeFileSync(vmx, 'virtualhw.version = "21"\n');
      expect(vmwareHwVersion(vmx)).toBe('21');
      expect(vmwareHwVersion(join(dir, 'missing.vmx'))).toBeUndefined();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('parseGuestIpAddress', () => {
  it('accepts a dotted quad', () => {
    expect(parseGuestIpAddress('   192.168.64.10\n')).toBe('192.168.64.10');
  });

  it('rejects the error text and 0.0.0.0', () => {
    expect(parseGuestIpAddress('The VMware Tools are not running\n')).toBeUndefined();
    expect(parseGuestIpAddress('  0.0.0.0\n')).toBeUndefined();
  });
});

describe('parseToolsState', () => {
  it('returns the last non-empty line', () => {
    expect(parseToolsState('Running VMware Tools: TRUE\nrunning\n')).toBe('running');
    expect(parseToolsState('')).toBeUndefined();
  });
});

describe('sharedFolderAlreadyExists', () => {
  it('recognizes the addSharedFolder Already exists message', () => {
    expect(sharedFolderAlreadyExists('Error: The share "work" already exists')).toBe(true);
    expect(sharedFolderAlreadyExists('The VMware Tools are not running')).toBe(false);
  });
});
