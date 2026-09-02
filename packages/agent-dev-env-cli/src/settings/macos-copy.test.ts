import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import * as macos from './macos.js';
import { stageSanitizedGitconfig } from './macos-copy.js';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('stageSanitizedGitconfig', () => {
  it('stages the sanitized content (host home rewritten to the guest home)', () => {
    const home = mkdtempSync(join(tmpdir(), 'settings-home-'));
    const staging = mkdtempSync(join(tmpdir(), 'settings-stage-'));
    writeFileSync(join(home, '.gitconfig'), `helper = ${home}/.ssh/helper.sh\n`);

    expect(stageSanitizedGitconfig(home, staging)).toBe(true);
    expect(readFileSync(join(staging, '.gitconfig'), 'utf8')).toBe(
      'helper = /Users/admin/.ssh/helper.sh\n',
    );
  });

  it('ships the raw file as-is when sanitization fails', () => {
    const home = mkdtempSync(join(tmpdir(), 'settings-home-'));
    const staging = mkdtempSync(join(tmpdir(), 'settings-stage-'));
    writeFileSync(join(home, '.gitconfig'), '[user]\n\tname = tester\n');
    vi.spyOn(macos, 'sanitizeGitconfig').mockImplementation(() => {
      throw new Error('parse failed');
    });

    expect(stageSanitizedGitconfig(home, staging)).toBe(true);
    expect(readFileSync(join(staging, '.gitconfig'), 'utf8')).toBe('[user]\n\tname = tester\n');
  });

  it('stages nothing and reports false when the source cannot be read or copied', () => {
    const home = mkdtempSync(join(tmpdir(), 'settings-home-'));
    const staging = mkdtempSync(join(tmpdir(), 'settings-stage-'));
    // A directory passes collectSettingsFiles' existsSync check but cannot
    // be read or copied as a file, so staging fails on both paths.
    mkdirSync(join(home, '.gitconfig'));

    expect(stageSanitizedGitconfig(home, staging)).toBe(false);
  });
});
