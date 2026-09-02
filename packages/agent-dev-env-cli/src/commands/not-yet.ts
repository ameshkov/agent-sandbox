// commands/not-yet.ts — the placeholder for commands/platform combos that
// land in a later phase (windows/ubuntu runners). Same message as the
// Phase 1 placeholders, so the interface stays stable.

import { logger } from '../lib/logger.js';

/** Reports that a command is not implemented for the platform yet.
 *
 * @param command - The command name (run/stop/delete/sync).
 * @param platform - The platform that is not implemented.
 * @returns The exit code to use (1).
 */
export function notYet(command: string, platform: string): number {
  logger.warn(`${command} is not implemented for '${platform}' yet — it lands in a later phase.`);
  return 1;
}
