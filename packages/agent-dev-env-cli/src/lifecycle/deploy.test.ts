import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { run } from '../lib/exec.js';
import { resolveRequestedImages } from './catalog.js';
import { orasPushArgs, packageVmwareTar, tartPushArgs } from './deploy.js';

describe('deploy arg builders', () => {
  it('tartPushArgs pushes both tags with 3 MB chunks', () => {
    expect(
      tartPushArgs('sandbox-macos-tahoe', 'ghcr.io/me/img:1.2.0', 'ghcr.io/me/img:latest'),
    ).toEqual([
      'push',
      'sandbox-macos-tahoe',
      '--chunk-size',
      '3',
      'ghcr.io/me/img:1.2.0',
      'ghcr.io/me/img:latest',
    ]);
  });

  it('orasPushArgs pushes the bare file as an OCI artifact layer', () => {
    expect(
      orasPushArgs(
        'ghcr.io/me/img:1.2.0,latest',
        'img.qcow2',
        'application/vnd.agent-dev-env.qcow2',
      ),
    ).toEqual([
      'push',
      '--artifact-type',
      'application/vnd.agent-dev-env.qcow2',
      'ghcr.io/me/img:1.2.0,latest',
      'img.qcow2:application/vnd.oci.image.layer.v1.tar',
    ]);
  });
});

describe('deploy target resolution', () => {
  it('resolves all catalog images when nothing is requested', () => {
    const targets = resolveRequestedImages();
    expect(targets.map((i) => i.name)).toContain('sandbox-macos-tahoe');
    expect(resolveRequestedImages(['sandbox-macos-tahoe'])).toHaveLength(1);
    expect(() => resolveRequestedImages(['nope'])).toThrow(/No vars file found/);
  });
});

describe('packageVmwareTar', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'agent-dev-env-tar-'));
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('packs vmx+nvram+vmdk and excludes the vmware logs', async () => {
    for (const file of ['img.vmx', 'img.nvram', 'img-1.vmdk', 'vmware.log', 'vmware-2.log']) {
      writeFileSync(join(root, file), 'x');
    }
    const artifact = join(root, 'img.tar.gz');
    await packageVmwareTar(root, 'img', artifact);
    const listing = await run('tar', ['-tzf', artifact]);
    const names = listing.stdout.split('\n').filter(Boolean).sort();
    expect(names).toEqual(['img-1.vmdk', 'img.nvram', 'img.vmx']);
  });
});
