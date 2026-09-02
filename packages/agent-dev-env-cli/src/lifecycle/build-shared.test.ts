import { mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { resolveImage } from './catalog.js';
import {
  findTemplateFile,
  materializeContext,
  normalizeSha,
  qemuImgCompressArgs,
  stringVar,
  swtpmArgs,
  unzipVmxnet3Args,
  verifyIsoSha256,
  vmnet8SubnetFromDhcpConf,
  watchdogBootCommand,
} from './build-shared.js';

describe('build-shared pure helpers', () => {
  it('normalizeSha lowercases and strips whitespace', () => {
    expect(normalizeSha('  638AA2C8E94385B00F4F178D071E3DF0 \n')).toBe(
      '638aa2c8e94385b00f4f178d071e3df0',
    );
  });

  it('vmnet8SubnetFromDhcpConf reads the subnet line', () => {
    const conf = [
      '# VMware NAT config',
      'subnet 192.168.111.0 netmask 255.255.255.0 {',
      '  range 192.168.111.128 192.168.111.254;',
      '}',
    ].join('\n');
    expect(vmnet8SubnetFromDhcpConf(conf)).toBe('192.168.111.0');
    expect(vmnet8SubnetFromDhcpConf('no subnet here')).toBeUndefined();
  });

  it('watchdogBootCommand renders the grub autoinstall command', () => {
    expect(watchdogBootCommand('192.168.111.1', 8004)).toBe(
      'linux /casper/vmlinuz autoinstall ds=nocloud-net\\;s=' +
        'http://192.168.111.1:8004/ ---\ninitrd /casper/initrd\nboot',
    );
  });

  it('swtpmArgs match the wrapper invocation', () => {
    expect(swtpmArgs('/tmp/tpm', '/tmp/tpm/sock', '/tmp/tpm/pid')).toEqual([
      'socket',
      '--tpmstate',
      'dir=/tmp/tpm',
      '--ctrl',
      'type=unixio,path=/tmp/tpm/sock',
      '--log',
      'file=/tmp/tpm/log,level=20',
      '--pid',
      'file=/tmp/tpm/pid',
      '--tpm2',
      '--daemon',
    ]);
  });

  it('qemuImgCompressArgs zstd-converts to a tmp file', () => {
    expect(qemuImgCompressArgs('/out/img.qcow2')).toEqual([
      'convert',
      '-c',
      '-O',
      'qcow2',
      '-o',
      'compression_type=zstd',
      '/out/img.qcow2',
      '/out/img.qcow2.tmp',
    ]);
  });

  it('unzipVmxnet3Args stages the flat driver trio', () => {
    expect(unzipVmxnet3Args('/f/drivers.zip', '/stage')).toEqual([
      '-jo',
      '/f/drivers.zip',
      'vmxnet3/Win10_1709/ARM64/vmxnet3.cat',
      'vmxnet3/Win10_1709/ARM64/vmxnet3.inf',
      'vmxnet3/Win10_1709/ARM64/vmxnet3.sys',
      '-d',
      '/stage',
    ]);
  });
});

describe('build-shared context + vars', () => {
  let root: string;
  let data: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'agent-dev-env-build-root-'));
    data = mkdtempSync(join(tmpdir(), 'agent-dev-env-build-data-'));
    const platform = join(root, 'mac');
    mkdirSync(join(platform, 'vars'), { recursive: true });
    writeFileSync(
      join(platform, 'vars', 'sandbox-image.pkrvars.hcl'),
      ['image_version = "1.0.0"', 'disk_size = 160', 'iso_sha256 = ""'].join('\n'),
    );
    writeFileSync(join(platform, 'sandbox.pkr.hcl'), 'packer {}\n');
    writeFileSync(join(platform, 'qemu-with-tpm.sh'), '#!/bin/sh\n');
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(data, { recursive: true, force: true });
  });

  it('stringVar returns strings only', () => {
    const image = resolveImage('sandbox-image', { roots: [root] });
    expect(stringVar(image, 'iso_sha256')).toBe('');
    expect(stringVar(image, 'disk_size')).toBeUndefined();
  });

  it('findTemplateFile picks the first *.pkr.hcl', () => {
    expect(findTemplateFile(join(root, 'mac'))).toBe(join(root, 'mac', 'sandbox.pkr.hcl'));
    expect(() => findTemplateFile(data)).toThrow(/No Packer template/);
  });

  it('materializeContext copies the platform dir and chmods qemu-with-tpm.sh', () => {
    const image = resolveImage('sandbox-image', { roots: [root] });
    const context = materializeContext(image, { dataRoot: data });
    expect(context.platformDir).toBe(join(data, 'build-context', 'mac'));
    expect(context.templateFile).toBe(join(context.platformDir, 'sandbox.pkr.hcl'));
    const perms = statSync(join(context.platformDir, 'qemu-with-tpm.sh')).mode & 0o111;
    expect(perms).toBe(0o111);
  });
});

describe('build-shared sha256 verification', () => {
  let root: string;
  let file: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'agent-dev-env-sha-'));
    file = join(root, 'iso.iso');
    writeFileSync(file, 'fake iso content');
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('accepts a matching digest (case/whitespace-insensitive)', async () => {
    const digest = createHash('sha256').update('fake iso content').digest('hex');
    await expect(
      verifyIsoSha256(file, `  ${digest.toUpperCase()}  `, 'Windows ISO', '/vars/file'),
    ).resolves.toBeUndefined();
  });

  it('rejects a mismatching digest with the shell message', async () => {
    await expect(
      verifyIsoSha256(file, '0'.repeat(64), 'Windows ISO', '/vars/file'),
    ).rejects.toThrow(/SHA256 mismatch for the Windows ISO\.\n  expected: .*\n  actual:/);
  });

  it('skips verification when the digest is empty', async () => {
    await expect(verifyIsoSha256(file, '', 'Windows ISO', '/vars/file')).resolves.toBeUndefined();
  });
});
