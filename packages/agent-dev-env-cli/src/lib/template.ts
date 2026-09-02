// template.ts — placeholder substitution shared by every piece of
// scaffolding the runners render from templates.
//
// The shell scripts substituted with sed (`s|{{TOKEN}}|value|g`); this is
// the unified replacement for all of them. Tokens are {{UPPER_SNAKE}}; an
// unknown token is left untouched (sed only replaced the tokens it was
// told about, too). The guest-side bridge assets migrated from `__X__`
// placeholders to {{TOKEN}} in the same unification.

import { escapeRegex } from './regex.js';

const TOKEN_RE = /\{\{([A-Za-z0-9_]+)\}\}/g;

/** Replaces every `{{TOKEN}}` occurrence with the substitution
 *  value. Tokens not present in `substitutions` are left as-is.
 * @param template - The template text.
 * @param substitutions - Token → value map.
 * @returns The rendered text.
 */
export function render(template: string, substitutions: Record<string, string | number>): string {
  return template.replace(TOKEN_RE, (match, key: string) =>
    key in substitutions && substitutions[key] !== undefined ? String(substitutions[key]) : match,
  );
}

/** Drops the given heading line and everything after it the
 *  sed `/^<heading>$/,$d` the macOS/Ubuntu runners use to remove the SSH
 *  agent section from the agent rules when no bridge is up. A heading
 *  that is not present leaves the content unchanged.
 * @param content - The document.
 * @param headingLine - The heading to drop from (e.g. `## SSH agent bridge`).
 * @returns The content up to (but excluding) the heading.
 */
export function dropSectionFrom(content: string, headingLine: string): string {
  const re = new RegExp(`^${escapeRegex(headingLine)}$`, 'm');
  const idx = content.search(re);
  if (idx === -1) {
    return content;
  }
  return content.slice(0, idx);
}
