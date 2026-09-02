import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { run } from './exec.js';
import {
  changelogHasTagEntry,
  createAnnotatedTag,
  isWorkingTreeClean,
  pushTag,
  tagExists,
} from './git.js';

async function git(...args: string[]): Promise<void> {
  const res = await run('git', args);
  if (res.code !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${res.stderr}`);
  }
}

describe('git release-tag helpers', () => {
  let root: string;

  beforeEach(async () => {
    root = mkdtempSync(join(tmpdir(), 'agent-dev-env-git-'));
    await git('init', '-b', 'main', root);
    await git('-C', root, 'config', 'user.email', 'test@example.com');
    await git('-C', root, 'config', 'user.name', 'Test');
    writeFileSync(join(root, 'file.txt'), 'v1');
    await git('-C', root, 'add', '.');
    await git('-C', root, 'commit', '-m', 'initial');
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('isWorkingTreeClean: true after a commit, false when modified or staged', async () => {
    expect(await isWorkingTreeClean(root)).toBe(true);
    writeFileSync(join(root, 'file.txt'), 'v2');
    expect(await isWorkingTreeClean(root)).toBe(false);
    await git('-C', root, 'add', '.');
    expect(await isWorkingTreeClean(root)).toBe(false);
  });

  it('changelogHasTagEntry matches the [tag] heading line', () => {
    expect(
      changelogHasTagEntry('# Changelog\n\n## [mac-v1.2.0] - 2026-09-01\n\n- x\n', 'mac-v1.2.0'),
    ).toBe(true);
    expect(changelogHasTagEntry('# Changelog\n', 'mac-v1.2.0')).toBe(false);
  });

  it('tagExists + createAnnotatedTag + pushTag against a bare remote', async () => {
    const remote = mkdtempSync(join(tmpdir(), 'agent-dev-env-remote-'));
    await git('init', '--bare', remote);
    await git('-C', root, 'remote', 'add', 'origin', remote);
    await git('-C', root, 'push', '-u', 'origin', 'main');

    expect(await tagExists(root, 'mac-v1.2.0')).toBe(false);
    await createAnnotatedTag(root, 'mac-v1.2.0', 'Release sandbox-macos-tahoe v1.2.0');
    expect(await tagExists(root, 'mac-v1.2.0')).toBe(true);
    await pushTag(root, 'mac-v1.2.0');

    const remoteTag = await run('git', [
      '-C',
      remote,
      'rev-parse',
      '--verify',
      '--quiet',
      'refs/tags/mac-v1.2.0',
    ]);
    expect(remoteTag.code).toBe(0);
    rmSync(remote, { recursive: true, force: true });
  });
});
