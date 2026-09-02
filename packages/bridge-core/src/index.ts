// index.ts — bridge-core's entry point (bundled to
// dist/assets/bridge/bridge.js and spawned detached by the runner):
//
//   bridge --listen <endpoint> --forward <endpoint> [--pidfile PATH]
//
// The same forwarder code powers the guest agents (they import
// `runBridge` with their own role-resolved endpoints).

import { rmSync, writeFileSync } from 'node:fs';
import { parseEndpoint, type Endpoint } from './endpoints.js';
import { startForwarder, type ForwarderOptions } from './forwarder.js';

export interface BridgeArgs {
  listen: Endpoint;
  forward: Endpoint;
  pidfile?: string;
}

export interface RunBridgeOptions extends ForwarderOptions {
  /** Optional pidfile written on start, removed on exit. */
  pidfile?: string;
}

/** Parses the bridge CLI arguments (--listen, --forward, --pidfile). */
export function parseBridgeArgs(argv: string[]): BridgeArgs {
  const values = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    if (flag === '--listen' || flag === '--forward' || flag === '--pidfile') {
      values.set(flag, argv[i + 1] ?? '');
    } else {
      throw new Error(`unknown argument: ${flag}`);
    }
  }
  const listenSpec = values.get('--listen');
  const forwardSpec = values.get('--forward');
  if (!listenSpec || !forwardSpec) {
    throw new Error('usage: bridge --listen <endpoint> --forward <endpoint> [--pidfile PATH]');
  }
  const pidfile = values.get('--pidfile');
  return {
    listen: parseEndpoint(listenSpec),
    forward: parseEndpoint(forwardSpec),
    pidfile: pidfile || undefined,
  };
}

/** Starts the forwarder and blocks until SIGINT/SIGTERM.
 *
 * @param options - listen/forward endpoints, optional pidfile and log.
 * @returns 0 after a clean signal-driven stop.
 */
export async function runBridge(options: RunBridgeOptions): Promise<number> {
  const running = await startForwarder(options);
  if (options.pidfile) {
    writeFileSync(options.pidfile, `${process.pid}\n`);
  }
  await new Promise<void>((resolve) => {
    const stop = (): void => {
      void running.close().then(() => {
        if (options.pidfile) {
          rmSync(options.pidfile, { force: true });
        }
        resolve();
      });
    };
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
  });
  return 0;
}

/** The standalone CLI entry (host-side bridge). */
export async function main(argv: string[]): Promise<number> {
  const args = parseBridgeArgs(argv);
  return runBridge({
    listen: args.listen,
    forward: args.forward,
    pidfile: args.pidfile,
    log: (message) => process.stderr.write(`${message}\n`),
  });
}
