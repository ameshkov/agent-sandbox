// lib/network.ts — NAT-segment address resolution for the VMware runners
// (the shell's find_host_alias + the x.y.z.1 fallback). VMware Fusion's
// NAT is userspace (vmnetd): the guest's gateway is x.y.z.2 and the
// host's own interface on that segment is x.y.z.1 (a dynamically named
// bridge — there is no fixed vmnet8 device). The guest reaches the host
// directly at that address, so the host-side bridges bind it.
//
// The resolver is kept pure (ifconfig text in → host IP out) so the
// parsing is unit-tested with a fixture; the runner wraps it with the
// ifconfig invocation and the fallback.

import { run } from './exec.js';

/** @internal — extracts the first host IPv4 address on the guest's /24
 *  from `ifconfig` output, excluding the guest IP itself (the awk port:
 *  scan `inet` lines, keep addresses sharing the first three octets,
 *  drop the guest's own address, take the first).
 *
 * @param output - The raw `ifconfig` output.
 * @param guestIp - The guest's IP (as reported by vmrun).
 * @returns The host address, or undefined when none matches.
 */
export function hostAliasFromIfconfig(output: string, guestIp: string): string | undefined {
  const guest = guestIp.split('.');
  if (guest.length !== 4) {
    return undefined;
  }
  const candidates = new Set<string>();
  for (const line of output.split('\n')) {
    if (!/\binet\s/.test(line)) {
      continue;
    }
    const match = /\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/.exec(line);
    if (!match) {
      continue;
    }
    const ip = match[1];
    const parts = ip.split('.');
    if (parts[0] === guest[0] && parts[1] === guest[1] && parts[2] === guest[2]) {
      candidates.add(ip);
    }
  }
  for (const ip of candidates) {
    if (ip !== guestIp) {
      return ip;
    }
  }
  return undefined;
}

/** The host's address on the guest's NAT segment: scan the host
 *  interfaces for the /24, fall back to x.y.z.1 (the legacy default when
 *  no interface matches).
 *
 * @param guestIp - The guest's IP.
 * @returns The host alias, or undefined when the guest IP is not a
 *   dotted-quad (no segment to derive a host address from).
 */
export async function findHostAlias(guestIp: string): Promise<string | undefined> {
  if (guestIp.split('.').length !== 4) {
    return undefined;
  }
  const res = await run('ifconfig');
  const alias = res.code === 0 ? hostAliasFromIfconfig(res.stdout, guestIp) : undefined;
  return alias ?? `${guestIp.split('.').slice(0, 3).join('.')}.1`;
}
