import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { run } from '../lib/exec.js';
import { resolveImage } from './catalog.js';
import { platformTagName, releaseTag, tagImage } from './tag.js';

/** A real git repo with one image + a CHANGELOG entry. */
function initRepo(root: string, changelogWithEntry = true): void {
  const vars = join(root, 'images', 'mac', 'vars');
  mkdirSync(vars, { recursive: true });
  writeFileSync(
    join(vars, 'sandbox-macos-tahoe.pkrvars.hcl'),
    'macos_version = "tahoe"\nimage_version = "1.2.0"\n',
  );
  writeFileSync(
    join(root, 'images', 'mac', 'CHANGELOG.md'),
    changelogWithEntry
      ? '# Changelog\n\n## [mac-v1.2.0] - 2026-09-01\n\n- change\n'
      : '# Changelog\n',
  );
}

async function git(...args: string[]): Promise<void> {
  const res = await run('git', args);
  if (res.code !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${res.stderr}`);
  }
}

describe('tag naming', () => {
  it('derives <platform-dir>-v<version> from the vars file', () => {
    const image = resolveImage('sandbox-macos-tahoe');
    expect(platformTagName(image)).toBe('mac');
    expect(releaseTag(image)).toBe('mac-v1.6.0');
  });
});

describe('tagImage release flow', () => {
  let root: string;
  let remote: string;

  beforeEach(async () => {
    root = mkdtempSync(join(tmpdir(), 'agent-dev-env-tag-'));
    initRepo(root);
    remote = mkdtempSync(join(tmpdir(), 'agent-dev-env-tag-remote-'));
    await git('init', '-b', 'main', root);
    await git('-C', root, 'config', 'user.email', 'test@example.com');
    await git('-C', root, 'config', 'user.name', 'Test');
    await git('init', '--bare', remote);
    await git('-C', root, 'remote', 'add', 'origin', remote);
    await git('-C', root, 'add', '.');
    await git('-C', root, 'commit', '-m', 'release');
    await git('-C', root, 'push', '-u', 'origin', 'main');
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(remote, { recursive: true, force: true });
  });

  it('creates and pushes the annotated tag on a clean tree', async () => {
    const image = resolveImage('sandbox-macos-tahoe', { roots: [join(root, 'images')] });
    await tagImage(image, root);
    const tag = await run('git', ['-C', root, 'tag', '-l', 'mac-v1.2.0']);
    expect(tag.stdout.trim()).toBe('mac-v1.2.0');
    const pushed = await run('git', [
      '-C',
      remote,
      'rev-parse',
      '--verify',
      '--quiet',
      'refs/tags/mac-v1.2.0',
    ]);
    expect(pushed.code).toBe(0);
  });

  it('refuses a dirty working tree (tracked changes only, like the shell)', async () => {
    const varsFile = join(root, 'images', 'mac', 'vars', 'sandbox-macos-tahoe.pkrvars.hcl');
    writeFileSync(varsFile, 'image_version = "1.2.0"\n');
    const image = resolveImage('sandbox-macos-tahoe', { roots: [join(root, 'images')] });
    await expect(tagImage(image, root)).rejects.toThrow(/Working tree is dirty/);
  });

  it('refuses an existing tag', async () => {
    await git('-C', root, 'tag', 'mac-v1.2.0');
    const image = resolveImage('sandbox-macos-tahoe', { roots: [join(root, 'images')] });
    await expect(tagImage(image, root)).rejects.toThrow(/Tag 'mac-v1.2.0' already exists/);
  });

  it('refuses a missing CHANGELOG entry', async () => {
    const root2 = mkdtempSync(join(tmpdir(), 'agent-dev-env-tag-noentry-'));
    initRepo(root2, false);
    await git('init', '-b', 'main', root2);
    await git('-C', root2, 'config', 'user.email', 'test@example.com');
    await git('-C', root2, 'config', 'user.name', 'Test');
    await git('-C', root2, 'add', '.');
    await git('-C', root2, 'commit', '-m', 'release');
    const image = resolveImage('sandbox-macos-tahoe', { roots: [join(root2, 'images')] });
    await expect(tagImage(image, root2)).rejects.toThrow(/No CHANGELOG entry for \[mac-v1.2.0\]/);
    rmSync(root2, { recursive: true, force: true });
  });
});
