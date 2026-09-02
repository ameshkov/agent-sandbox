// commands/not-yet.ts — the placeholder for the remaining unsupported
// command/platform combo: `sync` on the Windows platforms (the settings
// copy is tart/ssh2-based, like macOS/Ubuntu, and Windows has no such
// transport yet).

import { logger } from '../lib/logger.js';

/** Reports that a command is not supported for the platform.
 *
 * @param command - The command name (run/stop/delete/sync).
 * @param platform - The platform that is not supported.
 * @returns The exit code to use (1).
 */
export function notYet(command: string, platform: string): number {
  logger.warn(`${command} is not supported for '${platform}'.`);
  return 1;
}
