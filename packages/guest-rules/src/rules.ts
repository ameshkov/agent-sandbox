// rules.ts — the guest agent rules probe/install logic shared by the
// macOS and Ubuntu guest agents. Port of the shell heredocs
// (GUEST_RULES_PROBE / GUEST_RULES_FORCE in run-macos-sandbox.sh):
// the rendered rules content is streamed to the agent on stdin; the
// probe only inspects the guest and reports the most significant pending
// action, the overwrite writes both targets and refreshes the marker.
//
// Action precedence (most significant first): conflict (user-modified
// file) > install (missing file) > update (file we installed, content
// changed) > uptodate (nothing to do).

import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export type RulesAction = 'conflict' | 'install' | 'update' | 'uptodate';

/** The rules targets + marker under a guest home directory. */
export function rulesPaths(home: string): { marker: string; targets: string[] } {
  return {
    marker: join(home, '.config', 'agent-dev-env', 'agent-rules.sha256'),
    targets: [
      join(home, '.config', 'opencode', 'AGENTS.md'),
      join(home, '.copilot', 'copilot-instructions.md'),
    ],
  };
}

function sha256(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

function readMaybe(path: string): string | undefined {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return undefined;
  }
}

/** Inspects the guest and reports the pending action (no writes). */
export function rulesAction(home: string, content: string): RulesAction {
  const { marker, targets } = rulesPaths(home);
  const newSha = sha256(content);
  const prevSha = readMaybe(marker)?.trim();

  let conflict = false;
  let install = false;
  let update = false;

  for (const target of targets) {
    const current = readMaybe(target);
    if (current === undefined) {
      install = true;
    } else if (sha256(current) === newSha) {
      // already current
    } else if (prevSha !== undefined && sha256(current) === prevSha) {
      update = true;
    } else {
      conflict = true;
    }
  }

  if (conflict) return 'conflict';
  if (install) return 'install';
  if (update) return 'update';
  return 'uptodate';
}

/** Overwrites both targets with the rendered content + refreshes the
 *  marker. Call only after the user confirmed the action. */
export function applyRules(home: string, content: string): void {
  const { marker, targets } = rulesPaths(home);
  for (const target of targets) {
    mkdirSync(join(target, '..'), { recursive: true });
    writeFileSync(target, content);
  }
  mkdirSync(join(marker, '..'), { recursive: true });
  writeFileSync(marker, `${sha256(content)}\n`);
}
