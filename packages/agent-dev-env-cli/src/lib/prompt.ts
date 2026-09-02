// prompt.ts — interactive confirm, ported 1:1 from the shell confirm():
//
//   prompt "…" [y|n]   ->   "… [Y/n] "  (or "… [y/N] ")
//   yes answers: y | Y | yes | YES
//   empty answer: the default (y -> yes, n -> no)
//   anything else: no
//   EOF (non-interactive input that ran dry): no — the shell's `read`
//   fails, which returns 1 (no), always.
//
// The shell also prints a newline right after the prompt when stdin is not
// a TTY, because nothing will echo it otherwise — kept here.

import { createInterface, type Interface } from 'node:readline';
import { stdin as processStdin, stdout as processStdout } from 'node:process';
import { logger, type LoggerStream } from './logger.js';

/** Options for confirm (default answer + injectable streams). */
export interface ConfirmOptions {
  /** Default when the user hits enter. Default: 'n'. */
  default?: 'y' | 'n';
  /** Injectable input (tests). Default: process.stdin. */
  input?: NodeJS.ReadableStream;
  /** Injectable output (tests). Default: process.stdout. */
  output?: LoggerStream;
}

const YES_ANSWERS = new Set(['y', 'Y', 'yes', 'YES']);

/** Asks for a yes/no confirmation; resolves true when the user confirms.
 *
 * @param prompt - The question to display.
 * @param options - Default answer + injectable input/output (tests).
 * @returns True when confirmed, false otherwise (EOF is always false).
 */
export async function confirm(prompt: string, options: ConfirmOptions = {}): Promise<boolean> {
  const def = options.default ?? 'n';
  const hint = def === 'y' ? 'Y/n' : 'y/N';
  const output = options.output ?? processStdout;
  const input = options.input ?? processStdin;

  output.write(`${logger.bold(prompt)} [${hint}] `);
  if (!output.isTTY) {
    output.write('\n');
  }

  const rl = createInterface({ input, crlfDelay: Infinity });
  const answer = await readFirstLine(rl);
  rl.close();

  if (answer === null) {
    return false; // EOF — mirrors `read` failing (no).
  }
  if (YES_ANSWERS.has(answer.trim())) {
    return true;
  }
  if (answer.trim() === '') {
    return def === 'y';
  }
  return false;
}

/** First line read, or null on EOF. */
async function readFirstLine(rl: Interface): Promise<string | null> {
  for await (const line of rl) {
    return line;
  }
  return null;
}

/** The `--yes` semantics used by the runners: skip the prompt and accept
 *  the prompt's default — not an unconditional yes. A default-n prompt
 *  (e.g. "restart the running VM?") stays a no with --yes.
 *
 * @param message - The question to display (when asking).
 * @param options - Default answer + --yes flag; the rest (injectable
 *   input/output) is ConfirmOptions for tests.
 * @returns The (possibly defaulted) answer.
 */
export async function confirmDefault(
  message: string,
  options: { default: 'y' | 'n'; yes: boolean } & Omit<ConfirmOptions, 'default'>,
): Promise<boolean> {
  if (options.yes) {
    return options.default === 'y';
  }
  return confirm(message, { ...options, default: options.default });
}
