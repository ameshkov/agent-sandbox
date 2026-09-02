import { describe, expect, it } from 'vitest';
import { DEFAULT_GHCR_OWNER, ownerFromGitRemote, registryRef, resolveOwnerFrom } from './ghcr.js';

describe('ghcr', () => {
  it('extracts the owner from https remotes', () => {
    expect(ownerFromGitRemote('https://github.com/ameshkov/agent-dev-env.git')).toBe('ameshkov');
    expect(ownerFromGitRemote('https://github.com/hello/world')).toBe('hello');
  });

  it('extracts the owner from git@ ssh remotes', () => {
    expect(ownerFromGitRemote('git@github.com:ameshkov/agent-dev-env.git')).toBe('ameshkov');
    expect(ownerFromGitRemote('git@github.com:some-org/repo.git')).toBe('some-org');
  });

  it('extracts the owner from ssh:// urls', () => {
    expect(ownerFromGitRemote('ssh://git@github.com/ameshkov/repo.git')).toBe('ameshkov');
  });

  it('returns undefined when there is no owner', () => {
    expect(ownerFromGitRemote('https://github.com')).toBeUndefined();
    expect(ownerFromGitRemote('')).toBeUndefined();
  });

  it('resolution order: env > flag > remote > default', () => {
    const env = { GHCR_OWNER: 'env-owner' };
    expect(
      resolveOwnerFrom({ env, owner: 'flag-owner', remoteUrl: 'git@github.com:r/repo.git' }),
    ).toBe('env-owner');
    expect(
      resolveOwnerFrom({ env: {}, owner: 'flag-owner', remoteUrl: 'git@github.com:r/repo.git' }),
    ).toBe('flag-owner');
    expect(resolveOwnerFrom({ env: {}, remoteUrl: 'git@github.com:git-owner/repo.git' })).toBe(
      'git-owner',
    );
    expect(resolveOwnerFrom({ env: {} })).toBe(DEFAULT_GHCR_OWNER);
    expect(DEFAULT_GHCR_OWNER).toBe('ameshkov');
  });

  it('empty GHCR_OWNER is treated as unset', () => {
    expect(resolveOwnerFrom({ env: { GHCR_OWNER: '' }, owner: 'flag' })).toBe('flag');
  });

  it('registryRef builds ghcr.io/<owner>/<image>:<tag>', () => {
    expect(registryRef('sandbox-macos-tahoe', '1.6.0', 'ameshkov')).toBe(
      'ghcr.io/ameshkov/sandbox-macos-tahoe:1.6.0',
    );
  });
});
