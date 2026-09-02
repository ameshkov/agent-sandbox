import { describe, expect, it } from 'vitest';
import { resolvePaths } from './paths.js';

const HOME = '/home/tester';

describe('paths', () => {
  it('resolves macOS defaults', () => {
    const p = resolvePaths({ env: {}, home: HOME, platform: 'darwin' });
    expect(p.data).toBe(`${HOME}/Library/Application Support/agent-dev-env`);
    expect(p.logs).toBe(`${HOME}/Library/Logs/agent-dev-env`);
    expect(p.cache).toBe(`${HOME}/Library/Caches/agent-dev-env`);
  });

  it('resolves Linux defaults', () => {
    const p = resolvePaths({ env: {}, home: HOME, platform: 'linux' });
    expect(p.data).toBe(`${HOME}/.local/share/agent-dev-env`);
    expect(p.logs).toBe(`${HOME}/.local/state/agent-dev-env`);
    expect(p.cache).toBe(`${HOME}/.cache/agent-dev-env`);
  });

  it('honors XDG_* when set, on any OS', () => {
    const p = resolvePaths({
      env: {
        XDG_DATA_HOME: '/xdg/data',
        XDG_STATE_HOME: '/xdg/state',
        XDG_CACHE_HOME: '/xdg/cache',
      },
      home: HOME,
      platform: 'linux',
    });
    expect(p.data).toBe('/xdg/data');
    expect(p.logs).toBe('/xdg/state');
    expect(p.cache).toBe('/xdg/cache');

    const darwin = resolvePaths({
      env: { XDG_DATA_HOME: '/xdg/data' },
      home: HOME,
      platform: 'darwin',
    });
    expect(darwin.data).toBe('/xdg/data');
    expect(darwin.logs).toBe(`${HOME}/Library/Logs/agent-dev-env`);
  });

  it('AGENT_DEV_ENV_* overrides XDG_*', () => {
    const p = resolvePaths({
      env: {
        AGENT_DEV_ENV_DATA_HOME: '/ade/data',
        AGENT_DEV_ENV_LOG_DIR: '/ade/logs',
        AGENT_DEV_ENV_CACHE_DIR: '/ade/cache',
        XDG_DATA_HOME: '/xdg/data',
        XDG_STATE_HOME: '/xdg/state',
        XDG_CACHE_HOME: '/xdg/cache',
      },
      home: HOME,
      platform: 'darwin',
    });
    expect(p.data).toBe('/ade/data');
    expect(p.logs).toBe('/ade/logs');
    expect(p.cache).toBe('/ade/cache');
  });

  it('empty values fall back (no empty-string overrides)', () => {
    const p = resolvePaths({
      env: {
        AGENT_DEV_ENV_DATA_HOME: '',
        XDG_DATA_HOME: '',
      },
      home: HOME,
      platform: 'linux',
    });
    expect(p.data).toBe(`${HOME}/.local/share/agent-dev-env`);
  });
});
