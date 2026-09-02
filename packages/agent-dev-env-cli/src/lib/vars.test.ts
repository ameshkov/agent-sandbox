import { describe, expect, it } from 'vitest';
import {
  parseVars,
  readBoolVar,
  readNumberVar,
  readPortVar,
  readQuotedVar,
  readVar,
  requireQuotedVar,
} from './vars.js';

describe('vars', () => {
  const sample = `# comment line
macos_version = "tahoe"
xcode_version = "26.4.1"
disk_size = 160
cpu_count = 4
enabled = true
disabled = false
openchamber_port = 4000
image_version = "1.6.0"`;

  it('reads quoted strings (the sed pattern parity)', () => {
    expect(readQuotedVar(sample, 'macos_version')).toBe('tahoe');
    expect(readQuotedVar(sample, 'image_version')).toBe('1.6.0');
    expect(readVar(sample, 'image_version')).toBe('1.6.0');
  });

  it('reads numbers', () => {
    expect(readNumberVar(sample, 'disk_size')).toBe(160);
    expect(readNumberVar(sample, 'cpu_count')).toBe(4);
    expect(readVar(sample, 'disk_size')).toBe(160);
  });

  it('reads booleans', () => {
    expect(readBoolVar(sample, 'enabled')).toBe(true);
    expect(readBoolVar(sample, 'disabled')).toBe(false);
  });

  it('returns undefined for missing or comment-only values', () => {
    expect(readQuotedVar(sample, 'nope')).toBeUndefined();
    expect(readNumberVar(sample, 'nope')).toBeUndefined();
    // A trailing comment does not match — same as the anchored sed pattern.
    expect(readQuotedVar('image_version = "1.6.0" # note', 'image_version')).toBeUndefined();
  });

  it('tolerates leading whitespace and blank lines', () => {
    expect(readQuotedVar('  image_version  =  "1.0.0"  ', 'image_version')).toBe('1.0.0');
    expect(readNumberVar('\n\n  disk_size = 200\n', 'disk_size')).toBe(200);
  });

  it('validates port ranges', () => {
    expect(readPortVar(sample, 'openchamber_port')).toBe(4000);
    expect(() => readPortVar('port = 0', 'port')).toThrow(RangeError);
    expect(() => readPortVar('port = 70000', 'port')).toThrow(RangeError);
  });

  it('requireQuotedVar throws with the shell-like message', () => {
    expect(() => requireQuotedVar(sample, 'image_version', '/x/y.pkrvars.hcl')).not.toThrow();
    expect(() => requireQuotedVar('disk_size = 100', 'image_version', '/x/y.pkrvars.hcl')).toThrow(
      'Could not read image_version from /x/y.pkrvars.hcl',
    );
  });

  it('parseVars collects every assignment', () => {
    const vars = parseVars(sample);
    expect(vars.macos_version).toBe('tahoe');
    expect(vars.disk_size).toBe(160);
    expect(vars.enabled).toBe(true);
    expect(vars.image_version).toBe('1.6.0');
    expect(Object.keys(vars)).toHaveLength(8);
  });
});
