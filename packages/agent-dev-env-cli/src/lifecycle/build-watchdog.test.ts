import { chmodSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { watchdogAssets, ocrNeedsCompile, swiftcArgs, watchdogPyArgs } from './build-watchdog.js';

describe('build-watchdog helpers', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'agent-dev-env-watchdog-'));
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('watchdogAssets resolves paths under the given root', () => {
    expect(watchdogAssets(root)).toEqual({
      python: join(root, 'watch-build.py'),
      ocrSwift: join(root, 'watch-build-ocr.swift'),
    });
  });

  it('swiftcArgs are the -O compile argv', () => {
    expect(swiftcArgs('/src/ocr.swift', '/out/ocr')).toEqual([
      '-O',
      '/src/ocr.swift',
      '-o',
      '/out/ocr',
    ]);
  });

  it('watchdogPyArgs is python3 <py> <port> <outdir> <ocr>', () => {
    expect(watchdogPyArgs(5901, '/frames', '/frames/ocr', '/assets/watch-build.py')).toEqual([
      '/assets/watch-build.py',
      '5901',
      '/frames',
      '/frames/ocr',
    ]);
  });

  it('ocrNeedsCompile recompiles a missing binary', () => {
    const src = join(root, 'ocr.swift');
    writeFileSync(src, 'import Vision');
    expect(ocrNeedsCompile(join(root, 'ocr'), src)).toBe(true);
  });

  it('ocrNeedsCompile recompiles a newer source', () => {
    const src = join(root, 'ocr.swift');
    const ocr = join(root, 'ocr');
    writeFileSync(src, 'import Vision');
    writeFileSync(ocr, 'binary');
    chmodSync(ocr, 0o755);
    utimesSync(src, new Date(), new Date(Date.now() + 10_000));
    expect(ocrNeedsCompile(ocr, src)).toBe(true);
  });

  it('ocrNeedsCompile keeps a fresh executable', () => {
    const src = join(root, 'ocr.swift');
    const ocr = join(root, 'ocr');
    writeFileSync(src, 'import Vision');
    writeFileSync(ocr, 'binary');
    chmodSync(ocr, 0o755);
    utimesSync(ocr, new Date(), new Date(Date.now() + 5000));
    expect(ocrNeedsCompile(ocr, src)).toBe(false);
  });
});
