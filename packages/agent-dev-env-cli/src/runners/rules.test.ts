import { describe, expect, it } from 'vitest';
import { renderAgentRules } from './rules.js';

const SAMPLE = [
  '# Sandbox VM environment',
  '',
  '## Paths',
  '',
  '- shared at `{{GUEST_MOUNT}}` (host `{{HOST_WORK_DIR}}`)',
  '',
  '## Docker',
  '',
  '- use the host engine',
  '',
  '## SSH agent bridge',
  '',
  '- the host agent is bridged',
  '',
  '',
].join('\n');

describe('renderAgentRules', () => {
  it('substitutes the work dir and guest mount', () => {
    const out = renderAgentRules(
      SAMPLE,
      { HOST_WORK_DIR: '/Volumes/dev', GUEST_MOUNT: '/Volumes/My Shared Files/dev' },
      true,
    );
    expect(out).toContain('`/Volumes/My Shared Files/dev`');
    expect(out).toContain('`/Volumes/dev`');
  });

  it('drops the SSH section when the agent bridge is not up', () => {
    const out = renderAgentRules(
      SAMPLE,
      { HOST_WORK_DIR: '/Volumes/dev', GUEST_MOUNT: '/Volumes/My Shared Files/dev' },
      false,
    );
    expect(out).not.toContain('SSH agent bridge');
    expect(out).toContain('use the host engine');
  });

  it('keeps the SSH section when the bridge is up', () => {
    const out = renderAgentRules(
      SAMPLE,
      { HOST_WORK_DIR: '/Volumes/dev', GUEST_MOUNT: '/Volumes/My Shared Files/dev' },
      true,
    );
    expect(out).toContain('## SSH agent bridge');
  });

  it('leaves an unknown token alone (sed parity)', () => {
    const out = renderAgentRules(
      SAMPLE,
      { HOST_WORK_DIR: '/Volumes/dev', GUEST_MOUNT: '/Volumes/My Shared Files/dev', EXTRA: 'x' },
      true,
    );
    // EXTRA is not in the text; the renderer must not invent tokens.
    expect(out).not.toContain('EXTRA');
  });
});
