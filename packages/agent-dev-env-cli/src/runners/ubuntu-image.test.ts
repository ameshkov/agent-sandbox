import { describe, expect, it } from 'vitest';
import { archiveIdentity } from './ubuntu-image.js';

describe('archiveIdentity', () => {
  it('binds the path, size and mtime (seconds) into one marker', () => {
    expect(archiveIdentity('/tmp/image.tar.gz', 1234, 1_700_000_123_456)).toBe(
      '/tmp/image.tar.gz|1234|1700000123',
    );
  });

  it('detects a rebuild at the same path via size/mtime', () => {
    const first = archiveIdentity('/tmp/image.tar.gz', 1234, 1_700_000_000_000);
    const rebuilt = archiveIdentity('/tmp/image.tar.gz', 1235, 1_700_000_000_999);
    expect(rebuilt).not.toBe(first);
  });
});
