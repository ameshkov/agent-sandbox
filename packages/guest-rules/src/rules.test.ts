import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { applyRules, rulesAction, rulesPaths } from './rules.js';

const CONTENT = `# sandbox rules\n\n## Docker (remote engine)\n...\n`;

describe('guest-rules', () => {
  let home: string;

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), 'guest-rules-'));
  });

  afterEach(() => {
    rmSync(home, { recursive: true, force: true });
  });

  it('reports install when the targets are missing', () => {
    expect(rulesAction(home, CONTENT)).toBe('install');
  });

  it('reports uptodate when both targets match the marker', () => {
    applyRules(home, CONTENT);
    expect(rulesAction(home, CONTENT)).toBe('uptodate');
  });

  it('reports update when the content changed since the install', () => {
    applyRules(home, CONTENT);
    expect(rulesAction(home, `${CONTENT}newline\n`)).toBe('update');
  });

  it('reports conflict when the user edited a file we installed', () => {
    applyRules(home, CONTENT);
    const target = rulesPaths(home).targets[0];
    writeFileSync(target, 'user edits\n');
    expect(rulesAction(home, CONTENT)).toBe('conflict');
  });

  it('applyRules writes both targets and the marker', () => {
    applyRules(home, CONTENT);
    const { marker, targets } = rulesPaths(home);
    for (const target of targets) {
      expect(readFileSync(target, 'utf8')).toBe(CONTENT);
    }
    expect(readFileSync(marker, 'utf8')).toMatch(/^[0-9a-f]{64}\n$/);
  });
});
