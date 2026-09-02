import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { defaultImageFor, imageVersion, listImages, resolveImage, varsFor } from './catalog.js';

function writeVars(root: string, platformDir: string, image: string, content: string) {
  const dir = join(root, platformDir, 'vars');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${image}.pkrvars.hcl`), content);
}

describe('catalog', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'agent-dev-env-catalog-'));
    writeVars(
      root,
      'mac',
      'sandbox-macos-tahoe',
      ['macos_version = "tahoe"', 'image_version = "1.6.0"', 'disk_size = 160'].join('\n'),
    );
    writeVars(
      root,
      'windows-arm64-qemu',
      'sandbox-windows-11-arm64-qemu',
      ['image_version = "1.1.0"', 'disk_size = 100'].join('\n'),
    );
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('discovers images with platform + varsFile', () => {
    const images = listImages({ roots: [root] });
    expect(images).toHaveLength(2);
    expect(images.map((i) => i.name)).toContain('sandbox-macos-tahoe');
    expect(images.map((i) => i.platform)).toEqual(
      expect.arrayContaining(['macos', 'windows-qemu']),
    );
    const mac = images.find((i) => i.name === 'sandbox-macos-tahoe');
    expect(mac?.varsFile).toBe(join(root, 'mac', 'vars', 'sandbox-macos-tahoe.pkrvars.hcl'));
  });

  it('resolveImage finds by name and throws with the shell message', () => {
    const mac = resolveImage('sandbox-macos-tahoe', { roots: [root] });
    expect(mac.platform).toBe('macos');
    expect(() => resolveImage('nope', { roots: [root] })).toThrow(
      /No vars file found for image 'nope'/,
    );
  });

  it('defaultImageFor picks the platform default', () => {
    expect(defaultImageFor('macos', { roots: [root] }).name).toBe('sandbox-macos-tahoe');
    expect(() => defaultImageFor('ubuntu-vmware', { roots: [root] })).toThrow(
      /No image found for platform 'ubuntu-vmware'/,
    );
  });

  it('imageVersion + varsFor read from the vars file', () => {
    const mac = resolveImage('sandbox-macos-tahoe', { roots: [root] });
    expect(imageVersion(mac)).toBe('1.6.0');
    expect(varsFor(mac).disk_size).toBe(160);
  });

  it('lists nothing for an empty root', () => {
    const empty = mkdtempSync(join(tmpdir(), 'agent-dev-env-empty-'));
    expect(listImages({ roots: [empty] })).toHaveLength(0);
    expect(existsSync(empty)).toBe(true);
    rmSync(empty, { recursive: true, force: true });
  });
});
