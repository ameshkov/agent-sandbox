// regex.ts — tiny shared helpers.

/** Escapes a string so it matches literally in a RegExp.
 *
 * @param text - The string to escape.
 * @returns The escaped pattern fragment.
 */
export function escapeRegex(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
