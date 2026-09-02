import type { KnipConfig } from 'knip';

const config: KnipConfig = {
  entry: [
    'packages/agent-dev-env-cli/src/cli.ts!',
    'packages/*/src/index.ts!',
    'packages/bridge-core/src/bin.ts',
  ],
  project: ['packages/*/src/**/*.ts!', '!**/*.test.ts'],
  tags: ['-internal'],
  ignore: [
    // The host-side bridge entry: bundled by copy-assets.mjs (esbuild) to
    // dist/assets/bridge/bridge.js, never imported from TS.
    'packages/bridge-core/src/bin.ts',
    // The CLI package's build script, invoked by the root `build` script —
    // not part of the TypeScript module graph.
    'packages/agent-dev-env-cli/scripts/copy-assets.mjs',
  ],
  // OS utilities invoked by the guest agents / runners — system binaries,
  // not packages (knip would otherwise flag them as unlisted binaries).
  ignoreBinaries: ['netstat', 'schtasks', 'where.exe', 'tart', 'tar', 'lsof', 'ps'],
};

export default config;
