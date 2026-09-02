import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { isAlive, killTree, sleep, spawnDetached } from './exec.js';

// Node scripts that keep running until SIGKILL'd.
const DAEMON = 'setInterval(() => {}, 1000)';
const DAEMON_WITH_STDOUT = `console.log('daemon up'); ${DAEMON}`;

/** Active child-process pids (the internal Node handle list). */
function activeChildPids(): number[] {
  const getActive = (process as unknown as { _getActiveHandles?: () => unknown[] })
    ._getActiveHandles;
  if (!getActive) {
    return [];
  }
  return getActive()
    .filter((handle): handle is { pid: number } => {
      return typeof handle === 'object' && handle !== null && 'pid' in handle;
    })
    .map((handle) => handle.pid);
}

/** Polls until the probe returns true or the timeout passes. */
async function waitFor(probe: () => boolean, timeoutMs = 2000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (probe()) {
      return true;
    }
    await sleep(50);
  }
  return probe();
}

describe('spawnDetached', () => {
  const daemonPids: number[] = [];

  afterEach(async () => {
    for (const pid of daemonPids.splice(0)) {
      if (isAlive(pid)) {
        await killTree(pid, 'SIGKILL');
      }
    }
  });

  it('returns a live pid for a long-running daemon', () => {
    const pid = spawnDetached(process.execPath, ['-e', DAEMON]);
    daemonPids.push(pid);
    expect(pid).toBeGreaterThan(0);
    expect(isAlive(pid)).toBe(true);
  });

  it('does not keep the parent waiting for the child (unref)', () => {
    const pid = spawnDetached(process.execPath, ['-e', DAEMON]);
    daemonPids.push(pid);
    expect(activeChildPids()).not.toContain(pid);
  });

  it('writes stdio to the log file while the daemon runs', async () => {
    const logFile = join(tmpdir(), `agent-dev-env-spawn-detached-${process.pid}.log`);
    const pid = spawnDetached(process.execPath, ['-e', DAEMON_WITH_STDOUT], { logFile });
    daemonPids.push(pid);
    const hasLog = await waitFor(() => {
      try {
        return readFileSync(logFile, 'utf8').includes('daemon up');
      } catch {
        return false;
      }
    });
    expect(hasLog).toBe(true);
  });
});

describe('killTree', () => {
  it('kills a process and its descendants', async () => {
    // Parent spawns a detached grandchild, then keeps itself alive.
    const parentScript =
      `const { spawn } = require('node:child_process'); ` +
      `const child = spawn(process.execPath, ['-e', ${JSON.stringify(DAEMON)}], ` +
      `{ detached: true, stdio: 'ignore' }); child.unref(); ${DAEMON}`;
    const parentPid = spawnDetached(process.execPath, ['-e', parentScript]);
    expect(isAlive(parentPid)).toBe(true);

    let childPid: number | undefined;
    await waitFor(() => {
      const res = spawnSync('pgrep', ['-P', String(parentPid)], { encoding: 'utf8' });
      const pids = (res.stdout ?? '')
        .split('\n')
        .map((line) => Number.parseInt(line.trim(), 10))
        .filter((pid) => Number.isInteger(pid) && pid > 0);
      if (pids.length === 0) {
        return false;
      }
      childPid = pids[0];
      return true;
    });

    await killTree(parentPid, 'SIGKILL');
    expect(await waitFor(() => !isAlive(parentPid))).toBe(true);
    const childToCheck = childPid;
    expect(await waitFor(() => childToCheck === undefined || !isAlive(childToCheck))).toBe(true);
  });
});
