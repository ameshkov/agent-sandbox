// bin.ts — the host-side bridge CLI entry (bundled to
// dist/assets/bridge/bridge.js). Separate from index.ts so the guest
// agents can import the forwarder library without inheriting an
// auto-run — the direct-run guard below would otherwise fire inside a
// bundled guest agent (same process.argv[1] vs import.meta.url).

import { fileURLToPath } from 'node:url';
import { main } from './index.js';

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  void main(process.argv.slice(2)).then((code) => {
    process.exit(code);
  });
}
