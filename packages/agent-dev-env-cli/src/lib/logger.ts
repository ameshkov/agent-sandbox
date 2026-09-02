// logger.ts — output helpers for the CLI, ported 1:1 from the shell
// scripts' shared color/step helpers (scripts/lib/macos-settings.sh and the
// copies in every runner).
//
// Conventions (kept identical to the shell):
//   - stdout colors: bold, dim, green, yellow, blue, reset
//   - stderr colors: bold, red, yellow, reset
//   - colors only when the stream is a TTY and NO_COLOR is unset
//   - die(): "<name>: <msg>" (bold red) on stderr, exit 1
//   - warn(): "<name>: warning: <msg>" (bold yellow) on stderr
//   - title/step/info/cmd/ok() as in the shell runners (info is plain,
//     4-space indented; cmd is dim; ok is green)

import { env as processEnv, stderr as processStderr, stdout as processStdout } from 'node:process';

/** The ANSI color names the logger can emit. */
type ColorName = 'bold' | 'dim' | 'green' | 'yellow' | 'blue' | 'red';

/** A minimal writable stream (stdout/stderr or a fake). */
export interface LoggerStream {
  isTTY?: boolean;
  write(chunk: string): unknown;
}

/** Constructor options for a Logger instance. */
interface LoggerOptions {
  name?: string;
  stdout?: LoggerStream;
  stderr?: LoggerStream;
  env?: Record<string, string | undefined>;
}

const ANSI: Record<ColorName, string> = {
  bold: '\u001b[1m',
  dim: '\u001b[2m',
  green: '\u001b[32m',
  yellow: '\u001b[33m',
  blue: '\u001b[34m',
  red: '\u001b[31m',
};
const RESET = '\u001b[0m';

const DEFAULT_NAME = 'agent-dev-env';

/** @internal — the public surface is the `logger` instance below. */
export class Logger {
  readonly name: string;
  readonly stdout: LoggerStream;
  readonly stderr: LoggerStream;
  readonly env: Record<string, string | undefined>;

  constructor(options: LoggerOptions = {}) {
    this.name = options.name ?? DEFAULT_NAME;
    this.stdout = options.stdout ?? processStdout;
    this.stderr = options.stderr ?? processStderr;
    this.env = options.env ?? processEnv;
  }

  /** Whether this stream should carry color (TTY + NO_COLOR unset). */
  enabled(stream: LoggerStream): boolean {
    return Boolean(stream.isTTY) && !this.env.NO_COLOR;
  }

  /** ANSI code for the color on the given stream, or '' when disabled. */
  color(name: ColorName, stream: LoggerStream = this.stdout): string {
    return this.enabled(stream) ? ANSI[name] : '';
  }

  /** Reset code for the given stream ('' when disabled). */
  reset(stream: LoggerStream = this.stdout): string {
    return this.enabled(stream) ? RESET : '';
  }

  /** Bold text for the default stream — used by prompt() like the shell's
   *  `${c_bold}${prompt}${c_reset}`. */
  bold(text: string): string {
    return `${this.color('bold')}${text}${this.reset()}`;
  }

  die(message: string): never {
    const c = (name: ColorName): string => this.color(name, this.stderr);
    this.stderr.write(
      `${c('bold')}${c('red')}${this.name}: ${message}${this.reset(this.stderr)}\n`,
    );
    process.exit(1);
  }

  warn(message: string): void {
    const c = (name: ColorName): string => this.color(name, this.stderr);
    this.stderr.write(
      `${c('bold')}${c('yellow')}${this.name}: warning: ${message}${this.reset(this.stderr)}\n`,
    );
  }

  title(message: string): void {
    this.stdout.write(`${this.color('bold')}${message}${this.reset()}\n`);
  }

  step(message: string): void {
    this.stdout.write(`${this.color('bold')}${this.color('blue')}==> ${message}${this.reset()}\n`);
  }

  info(message: string): void {
    this.stdout.write(`    ${message}\n`);
  }

  cmd(message: string): void {
    this.stdout.write(`${this.color('dim')}    ${message}${this.reset()}\n`);
  }

  ok(message: string): void {
    this.stdout.write(`${this.color('green')}    ${message}${this.reset()}\n`);
  }

  /** Raw line on stdout (table output, no indent/color). */
  out(message: string): void {
    this.stdout.write(`${message}\n`);
  }

  /** Raw line on stderr (diagnostics not prefixed by the script name). */
  err(message: string): void {
    this.stderr.write(`${message}\n`);
  }
}

/** The default CLI logger (name: agent-dev-env). */
export const logger = new Logger();
