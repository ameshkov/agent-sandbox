#!/usr/bin/env node
//
// copy-assets.mjs — the build step for the agent-dev-env package.
//
// 1. Compiles the TypeScript CLI.
// 2. Bundles the workspace guest-side packages into single-file JS
//    artifacts (esbuild; node built-ins only, no runtime deps):
//      packages/bridge-core         -> dist/assets/bridge/bridge.js
//      packages/guest-agent-mac     -> dist/assets/guest/guest-agent-mac.js
//      packages/guest-agent-windows -> dist/assets/guest/guest-agent-windows.js
//      packages/guest-agent-ubuntu  -> dist/assets/guest/guest-agent-ubuntu.js
// 3. Copies the runtime assets and the images/ snapshot into dist/.
//
// The bundled artifacts are how guests get the bridge code: the runners
// SFTP them in and run them with node — no npm install inside guests.
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

// packages/agent-dev-env-cli/scripts/ -> repo root is three levels up.
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const cliRoot = join(repoRoot, 'packages', 'agent-dev-env-cli');
const dist = join(cliRoot, 'dist');
const assets = join(repoRoot, 'assets');
const images = join(repoRoot, 'images');

const bundles = [
  ['packages/bridge-core/src/bin.ts', 'dist/assets/bridge/bridge.js'],
  ['packages/guest-agent-mac/src/index.ts', 'dist/assets/guest/guest-agent-mac.js'],
  ['packages/guest-agent-windows/src/index.ts', 'dist/assets/guest/guest-agent-windows.js'],
  ['packages/guest-agent-ubuntu/src/index.ts', 'dist/assets/guest/guest-agent-ubuntu.js'],
];

async function main() {
  const tsc = join(repoRoot, 'node_modules', 'typescript', 'bin', 'tsc');
  execFileSync(process.execPath, [tsc, '-p', join(cliRoot, 'tsconfig.app.json')], {
    stdio: 'inherit',
  });

  // Regenerate dist/assets from scratch: src files removed from
  // assets/ or images/ must not survive in a stale dist copy.
  rmSync(join(dist, 'assets'), { recursive: true, force: true });
  mkdirSync(join(dist, 'assets'), { recursive: true });
  for (const [entry, outfile] of bundles) {
    await build({
      entryPoints: [join(repoRoot, entry)],
      bundle: true,
      platform: 'node',
      format: 'esm',
      target: 'node20',
      outfile: join(cliRoot, outfile),
      banner: { js: '#!/usr/bin/env node' },
      logLevel: 'warning',
    });
  }

  if (existsSync(assets)) {
    cpSync(assets, join(dist, 'assets'), { recursive: true });
  }
  if (existsSync(images)) {
    cpSync(images, join(dist, 'assets', 'images'), { recursive: true });
  }
  console.log(`copy-assets: dist/ ready (${dist})`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
