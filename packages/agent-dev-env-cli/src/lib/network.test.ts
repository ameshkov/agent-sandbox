import { describe, expect, it } from 'vitest';
import { hostAliasFromIfconfig } from './network.js';

const IFCONFIG_FIXTURE = [
  'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384',
  '\tinet 127.0.0.1 netmask 0xff000000',
  'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500',
  '\tinet 10.0.10.4 netmask 0xffffff00 broadcast 10.0.10.255',
  'bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500',
  '\tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255',
  '',
].join('\n');

describe('hostAliasFromIfconfig', () => {
  it('returns the host interface on the guest subnet', () => {
    expect(hostAliasFromIfconfig(IFCONFIG_FIXTURE, '192.168.64.10')).toBe('192.168.64.1');
  });

  it('ignores interfaces outside the guest subnet', () => {
    expect(hostAliasFromIfconfig(IFCONFIG_FIXTURE, '10.0.10.3')).toBe('10.0.10.4');
  });

  it('excludes the guest IP itself from the candidates', () => {
    // Only the guest IP matches the subnet — nothing to pick.
    const output = ['en0: flags=...', '\tinet 192.168.64.10 netmask 0xffffff00'].join('\n');
    expect(hostAliasFromIfconfig(output, '192.168.64.10')).toBeUndefined();
  });

  it('returns undefined for a malformed guest IP', () => {
    expect(hostAliasFromIfconfig(IFCONFIG_FIXTURE, 'nonsense')).toBeUndefined();
  });
});
