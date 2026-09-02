import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { paths } from './paths.js';
import {
  backingIdentity,
  buildQemuArgs,
  QEMU_EFI_CODE,
  QEMU_HOST_ALIAS,
  qemuBackingMarker,
  qemuEfivarsPath,
  qemuImagePath,
  qemuOverlayPath,
  qemuPidFile,
  qemuStateDir,
  qemuTpmDir,
  swtpmPidFile,
  swtpmSockPath,
} from './qemu.js';

describe('backingIdentity', () => {
  it('binds the path, size and mtime (seconds) into one marker', () => {
    expect(backingIdentity('/tmp/image.qcow2', 42, 1_700_000_123_456)).toBe(
      '/tmp/image.qcow2|42|1700000123',
    );
  });

  it('detects a rebuild at the same path via size/mtime', () => {
    const first = backingIdentity('/tmp/image.qcow2', 42, 1_700_000_000_000);
    const rebuilt = backingIdentity('/tmp/image.qcow2', 43, 1_700_000_000_999);
    expect(rebuilt).not.toBe(first);
  });
});

describe('qemu state paths', () => {
  it('derives the working-VM paths under <data>/windows-qemu/<image>', () => {
    const root = join(paths.data, 'windows-qemu', 'i');
    expect(qemuStateDir('i')).toBe(root);
    expect(qemuImagePath('i')).toBe(join(root, 'image', 'i.qcow2'));
    expect(qemuOverlayPath('i')).toBe(join(root, 'working', 'i.qcow2'));
    expect(qemuBackingMarker('i')).toBe(join(root, 'working', 'backing-image.txt'));
    expect(qemuEfivarsPath('i')).toBe(join(root, 'working', 'efivars.fd'));
    expect(qemuTpmDir('i')).toBe(join(root, 'working', 'tpm'));
    expect(qemuPidFile('i')).toBe(join(root, 'working', 'qemu.pid'));
    expect(swtpmPidFile('i')).toBe(join(root, 'working', 'swtpm.pid'));
    expect(swtpmSockPath('i')).toBe(join(root, 'working', 'swtpm.sock'));
  });
});

describe('buildQemuArgs', () => {
  const base = {
    efiCode: QEMU_EFI_CODE,
    efivars: '/state/working/efivars.fd',
    overlay: '/state/working/i.qcow2',
    tpmSock: '/state/working/swtpm.sock',
    sshPort: 2222,
    rdpPort: 3389,
    openchamberPort: 4000,
    winrmPort: 5985,
    cpuCount: 4,
    memoryMb: 8192,
    headless: false,
  };

  it('builds the exact launch_qemu wiring (virt/hvf/UEFI/swtpm/ports)', () => {
    const args = buildQemuArgs(base);
    expect(args).toContain('virt,gic-version=max');
    expect(args).toContain('hvf');
    expect(args).toContain('host');
    expect(args).toContain('4');
    expect(args).toContain('8192');
    expect(args).toContain(`if=pflash,format=raw,readonly=on,file=${QEMU_EFI_CODE}`);
    expect(args).toContain('if=pflash,format=raw,file=/state/working/efivars.fd');
    expect(args).toContain('file=/state/working/i.qcow2,if=virtio,format=qcow2');
    expect(args).toContain(
      'user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,' +
        'hostfwd=tcp:127.0.0.1:3389-:3389,' +
        'hostfwd=tcp:127.0.0.1:4000-:4000,' +
        'hostfwd=tcp:127.0.0.1:5985-:5985',
    );
    expect(args).toContain('tpm-tis-device,tpmdev=tpm0,ppi=off');
    expect(args).toContain('virtio-gpu-pci');
    expect(args).toContain('cocoa,zoom-to-fit=on');
  });

  it('swaps the cocoa display for -display none in headless mode', () => {
    expect(buildQemuArgs({ ...base, headless: true })).toContain('none');
    expect(buildQemuArgs({ ...base, headless: true })).not.toContain('cocoa,zoom-to-fit=on');
  });

  it('forwards the configurable ports when overridden', () => {
    const args = buildQemuArgs({ ...base, sshPort: 2200, rdpPort: 3399, winrmPort: 6000 });
    const netdev = args[args.indexOf('-netdev') + 1];
    expect(netdev).toContain('tcp:127.0.0.1:2200-:22');
    expect(netdev).toContain('tcp:127.0.0.1:3399-:3389');
    expect(netdev).toContain('tcp:127.0.0.1:6000-:5985');
  });
});

describe('QEMU_HOST_ALIAS', () => {
  it('is the user-mode NAT gateway the guest connects to', () => {
    expect(QEMU_HOST_ALIAS).toBe('10.0.2.2');
  });
});
