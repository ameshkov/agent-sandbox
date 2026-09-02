import { PassThrough } from 'node:stream';
import { describe, expect, it } from 'vitest';
import { confirm, confirmDefault } from './prompt.js';

/** A minimal writable sink the logger can use in tests. */
function outputSink(): { stream: PassThrough; written: () => string } {
  let text = '';
  const stream = new PassThrough();
  stream.write = (chunk: unknown) => {
    text += String(chunk);
    return true;
  };
  return { stream, written: () => text };
}

function inputStream(answer: string): PassThrough {
  const stream = new PassThrough();
  stream.end(answer);
  return stream;
}

describe('confirm', () => {
  it('accepts the y answer', async () => {
    const input = inputStream('y\n');
    const output = outputSink();
    await expect(confirm('Proceed?', { input, output: output.stream, default: 'n' })).resolves.toBe(
      true,
    );
  });

  it('an EOF (empty input) is always false', async () => {
    const input = new PassThrough();
    input.end();
    const output = outputSink();
    await expect(confirm('Proceed?', { input, output: output.stream, default: 'y' })).resolves.toBe(
      false,
    );
  });
});

describe('confirmDefault', () => {
  it('with --yes accepts the default n (never a forced yes)', async () => {
    const output = outputSink();
    await expect(
      confirmDefault('Restart the running VM?', { default: 'n', yes: true }),
    ).resolves.toBe(false);
    expect(output.written()).toBe('');
  });

  it('with --yes accepts the default y without prompting', async () => {
    const output = outputSink();
    await expect(confirmDefault('Pull it now?', { default: 'y', yes: true })).resolves.toBe(true);
    expect(output.written()).toBe('');
  });

  it('without --yes asks the user like confirm', async () => {
    const input = inputStream('y\n');
    const output = outputSink();
    await expect(
      confirmDefault('Pull it now?', { input, output: output.stream, default: 'y', yes: false }),
    ).resolves.toBe(true);
    expect(output.written()).toContain('Pull it now?');
  });
});
