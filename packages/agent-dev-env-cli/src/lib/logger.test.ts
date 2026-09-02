import { afterEach, describe, expect, it, vi } from 'vitest';
import { Logger, type LoggerStream } from './logger.js';

function fakeStream(): LoggerStream & { text: string } {
  const stream = {
    isTTY: true,
    text: '',
    write(chunk: string) {
      this.text += chunk;
    },
  };
  return stream;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('logger', () => {
  it('colors output on a TTY', () => {
    const out = fakeStream();
    const err = fakeStream();
    const log = new Logger({ name: 'agent-dev-env', stdout: out, stderr: err, env: {} });
    log.ok('copied');
    expect(out.text).toContain('\u001b[32m');
    expect(out.text).toContain('\u001b[0m');
  });

  it('stays plain with NO_COLOR', () => {
    const out = fakeStream();
    const err = fakeStream();
    const log = new Logger({
      name: 'agent-dev-env',
      stdout: out,
      stderr: err,
      env: { NO_COLOR: '1' },
    });
    log.ok('copied');
    log.title('title');
    log.step('step');
    log.cmd('cmd');
    expect(out.text).toBe('    copied\ntitle\n==> step\n    cmd\n');
  });

  it('info is plain and indented; ok/cmd carry color only on TTY', () => {
    const out = fakeStream();
    const log = new Logger({ name: 'x', stdout: out, stderr: fakeStream(), env: {} });
    log.info('hello');
    expect(out.text).toBe('    hello\n');
  });

  it('warn prefixes with the script name and warning:', () => {
    const err = fakeStream();
    const log = new Logger({ name: 'agent-dev-env', stdout: fakeStream(), stderr: err, env: {} });
    log.warn('socat missing');
    expect(err.text).toContain('agent-dev-env: warning: socat missing');
    expect(err.text).toContain('\u001b[33m');
  });

  it('die prints <name>: <msg> and exits 1', () => {
    const err = fakeStream();
    const log = new Logger({ name: 'agent-dev-env', stdout: fakeStream(), stderr: err, env: {} });
    const exit = vi.spyOn(process, 'exit').mockImplementation(() => {
      throw new Error('exit');
    });
    expect(() => log.die('boom')).toThrow('exit');
    expect(err.text).toContain('agent-dev-env: boom');
    expect(exit).toHaveBeenCalledWith(1);
  });

  it('non-TTY streams stay plain even without NO_COLOR', () => {
    const out = fakeStream();
    out.isTTY = false;
    const log = new Logger({ name: 'x', stdout: out, stderr: fakeStream(), env: {} });
    log.ok('plain');
    expect(out.text).toBe('    plain\n');
  });
});
