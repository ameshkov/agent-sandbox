// settings/macos.ts — the macOS user-settings copy: pure builders
// (collection, .gitconfig sanitization, guest-side marker scripts) —
// port of scripts/lib/macos-settings.sh, with the marker moved to the
// green-field `~/.config/agent-dev-env/` path (AGENTS.md conventions).
//
// The IO half (tar streams over `tart exec`) lives in macos-copy.ts; this
// module stays free of process spawning so the logic is unit-testable.
// The macOS-specific bits are the version, the guest home and the guest
// unpack/restart scripts — the shared set (markers, candidate files,
// sanitization) lives in settings/common.ts.

export type { SettingsState } from './common.js';
export {
  collectSettingsFiles,
  guestSettingsCheckScript,
  guestSettingsMarkerScript,
  sanitizeGitconfig,
} from './common.js';

/** Version of the settings copy. Bump when the file set or the copy logic
 *  changes: guests whose marker is older are offered the copy again.
 */
export const SETTINGS_VERSION = 9;

/** The sandbox user in the macOS base image — fixed, so host home paths
 *  are rewritten to it when the settings are copied (see sanitize).
 */
export const GUEST_HOME = '/Users/admin';

/** The guest-side tar unpack — `sh -c` command: extract + tighten ~/.ssh.
 *
 * @returns The command text.
 */
export function guestUnpackCommand(): string {
  return 'tar -C "$HOME" -xf - || exit 1; chmod 700 "$HOME/.ssh" 2>/dev/null || true';
}

/** The guest-side OpenChamber restart — `sh -s` stdin script (sources
 *  ~/.zprofile first: openchamber is npm-global via nvm, login-shell
 *  PATH only).
 *
 * @returns The script text.
 */
export function openchamberRestartScript(): string {
  return [
    'if [ -f "$HOME/.zprofile" ]; then',
    '    . "$HOME/.zprofile" 2>/dev/null || true',
    'fi',
    'exec openchamber restart',
    '',
  ].join('\n');
}
