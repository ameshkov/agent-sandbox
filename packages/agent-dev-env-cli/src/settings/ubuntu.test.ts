import { describe, expect, it } from 'vitest';
import { mapGuestPath, SETTINGS_VERSION } from './ubuntu.js';
import { guestSettingsCheckScript } from './common.js';

describe('mapGuestPath', () => {
  it('maps the VS Code user config to the Linux .config path', () => {
    expect(mapGuestPath('Library/Application Support/Code/User/settings.json')).toBe(
      '.config/Code/User/settings.json',
    );
    expect(mapGuestPath('Library/Application Support/Code/User/snippets')).toBe(
      '.config/Code/User/snippets',
    );
  });

  it('maps mcp-compress-router to the Linux XDG data dir', () => {
    expect(mapGuestPath('Library/Application Support/mcp-compress-router')).toBe(
      '.local/share/mcp-compress-router',
    );
    expect(mapGuestPath('Library/Application Support/mcp-compress-router/mcp.json')).toBe(
      '.local/share/mcp-compress-router',
    );
  });

  it('keeps everything else at the same relative path', () => {
    expect(mapGuestPath('.config/opencode/opencode.json')).toBe('.config/opencode/opencode.json');
    expect(mapGuestPath('.copilot/config.json')).toBe('.copilot/config.json');
    expect(mapGuestPath('.ssh/known_hosts')).toBe('.ssh/known_hosts');
    expect(mapGuestPath('.gitconfig')).toBe('.gitconfig');
  });
});

describe('Ubuntu settings constants', () => {
  it('keeps the legacy settings version 3 (fresh-guest semantics)', () => {
    expect(SETTINGS_VERSION).toBe(3);
  });

  it('embeds the green-field marker path in the check script', () => {
    const script = guestSettingsCheckScript();
    expect(script).toContain('$HOME/.config/agent-dev-env/settings-copied');
  });
});
