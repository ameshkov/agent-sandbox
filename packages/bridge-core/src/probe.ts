// probe.ts — "can a connection be established to this endpoint?" Used by
// the guest agents' `status` command (socket exists is not enough — the
// listener must actually service it) and by the runners' bridge checks.

import net from 'node:net';
import type { Endpoint } from './endpoints.js';

/** Tries to establish a connection; resolves true when one succeeds. */
export function canConnect(endpoint: Endpoint, timeoutMs = 500): Promise<boolean> {
  return new Promise((resolve) => {
    const socket =
      endpoint.kind === 'tcp'
        ? net.connect({ port: endpoint.port, host: endpoint.host })
        : net.connect({ path: endpoint.kind === 'unix' ? endpoint.path : endpoint.name });
    const done = (ok: boolean): void => {
      socket.destroy();
      resolve(ok);
    };
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
    setTimeout(() => done(false), timeoutMs);
  });
}
