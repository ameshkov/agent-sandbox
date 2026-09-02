// vars.ts — reading values out of Packer vars files (*.pkrvars.hcl).
//
// Port of the shell `read_var` sed pattern (scripts/build.sh, every runner):
//
//   ^[[:space:]]*NAME[[:space:]]*=[[:space:]]*"([^"]*)"[[:space:]]*$
//
// extended with number and boolean parsing (disk_size = 160, a flag =
// true), and with port validation for the port-like vars. The vars files
// are the single source of truth for versions and resources, so everything
// that needs a value (image_version for deploy/tag/list, disk_size/ports
// for doctor, guest passwords for the runners) reads them through here.

import { escapeRegex } from './regex.js';

export type VarValue = string | number | boolean;

/** Reads a quoted-string assignment: `name = "value"`.
 *
 * @param text - Vars file content.
 * @param name - The variable name.
 * @returns The value, or undefined when not present as a quoted string.
 */
export function readQuotedVar(text: string, name: string): string | undefined {
  const re = new RegExp(`^[ \\t]*${escapeRegex(name)}[ \\t]*=[ \\t]*"([^"]*)"[ \\t]*$`, 'm');
  const m = text.match(re);
  return m?.[1];
}

/** @internal — Integer assignment: `name = 160`.
 * @param text - Vars file content.
 * @param name - The variable name.
 * @returns The value, or undefined when not present as an integer.
 */
export function readNumberVar(text: string, name: string): number | undefined {
  const re = new RegExp(`^[ \\t]*${escapeRegex(name)}[ \\t]*=[ \\t]*(\\d+)[ \\t]*$`, 'm');
  const m = text.match(re);
  return m ? Number(m[1]) : undefined;
}

/** @internal — Boolean assignment: `name = true|false`.
 * @param text - Vars file content.
 * @param name - The variable name.
 * @returns The value, or undefined when not present as a boolean.
 */
export function readBoolVar(text: string, name: string): boolean | undefined {
  const re = new RegExp(`^[ \\t]*${escapeRegex(name)}[ \\t]*=[ \\t]*(true|false)[ \\t]*$`, 'm');
  const m = text.match(re);
  return m ? m[1] === 'true' : undefined;
}

/** @internal — Any assignment, string first (the shell only ever read
 *  quoted strings).
 * @param text - Vars file content.
 * @param name - The variable name.
 * @returns The string/number/boolean value, or undefined when absent.
 */
export function readVar(text: string, name: string): VarValue | undefined {
  return readQuotedVar(text, name) ?? readNumberVar(text, name) ?? readBoolVar(text, name);
}

/** @internal — Port assignment (number 1-65535).
 * @param text - Vars file content.
 * @param name - The variable name.
 * @returns The port, or undefined when absent.
 * @throws RangeError when the port is out of range.
 */
export function readPortVar(text: string, name: string): number | undefined {
  const v = readNumberVar(text, name);
  if (v !== undefined && (v < 1 || v > 65535)) {
    throw new RangeError(`port '${name}' is out of range (1-65535): ${v}`);
  }
  return v;
}

/** @internal — Quoted string that must exist — the pattern
 *  deploy.sh/tag.sh use for image_version, with the same error message
 *  shape.
 * @param text - Vars file content.
 * @param name - The variable name.
 * @param file - The source path, included in the error message.
 * @returns The quoted value.
 * @throws Error when the variable is missing.
 */
export function requireQuotedVar(text: string, name: string, file: string): string {
  const v = readQuotedVar(text, name);
  if (v === undefined) {
    throw new Error(`Could not read ${name} from ${file}`);
  }
  return v;
}

const ASSIGNMENT_RE =
  /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"]*)"|(\d+)|(true|false))[ \t]*$/gm;

/** Parses every assignment in a vars file (last value wins for duplicate
 *  keys).
 *
 * @param text - Vars file content.
 * @returns The name → value map.
 */
export function parseVars(text: string): Record<string, VarValue> {
  const out: Record<string, VarValue> = {};
  for (const m of text.matchAll(ASSIGNMENT_RE)) {
    const [, name, quoted, number, bool] = m;
    if (name !== undefined) {
      out[name] =
        quoted !== undefined ? quoted : number !== undefined ? Number(number) : bool === 'true';
    }
  }
  return out;
}
