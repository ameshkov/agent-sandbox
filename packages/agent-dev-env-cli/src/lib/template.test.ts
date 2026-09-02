import { describe, expect, it } from 'vitest';
import { dropSectionFrom, render } from './template.js';

describe('template', () => {
  it('replaces every {{TOKEN}} occurrence', () => {
    const out = render('a {{X}} b {{X}}', { X: '1' });
    expect(out).toBe('a 1 b 1');
  });

  it('replaces multiple different tokens', () => {
    const out = render('{{HOST_WORK_DIR}} -> {{GUEST_MOUNT}}', {
      HOST_WORK_DIR: '/Volumes/dev',
      GUEST_MOUNT: '/Volumes/My Shared Files/dev',
    });
    expect(out).toBe('/Volumes/dev -> /Volumes/My Shared Files/dev');
  });

  it('leaves unknown tokens untouched (sed parity)', () => {
    expect(render('x {{UNKNOWN}} y', { OTHER: 'v' })).toBe('x {{UNKNOWN}} y');
  });

  it('stringifies numeric substitutions', () => {
    expect(render('port {{PORT}}', { PORT: 4100 })).toBe('port 4100');
  });

  it('dropSectionFrom removes the heading and everything after', () => {
    const content = [
      '# rules',
      '',
      '## Docker (remote engine)',
      'docker rules...',
      '',
      '## SSH agent bridge',
      'ssh rules...',
    ].join('\n');
    const out = dropSectionFrom(content, '## SSH agent bridge');
    expect(out).toContain('docker rules');
    expect(out).not.toContain('ssh rules');
    expect(out).not.toContain('## SSH agent bridge');
  });

  it('dropSectionFrom keeps content without the heading', () => {
    const content = 'a\nb\n';
    expect(dropSectionFrom(content, '## SSH agent bridge')).toBe(content);
  });
});
