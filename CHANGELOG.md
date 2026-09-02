# Changelog

All notable changes to the `agent-dev-env` CLI.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The CLI version lives in `packages/agent-dev-env-cli/package.json`. Image
versions are tracked separately: each lives in its image's vars file
(`image_version`) and is recorded in the per-image changelog
(`images/<platform>/CHANGELOG.md`). The `[Unreleased]` section on top is
never removed — changes land there until the next release.

## [Unreleased]

### Added

- Create the `agent-dev-env` project (the first release):
    - the `agent-dev-env` npm CLI — TypeScript, commander — replacing the
      legacy shell scripts: per-platform runners (`run` / `stop` /
      `delete` / `sync`) for macOS (Tart), Windows 11 ARM64 (QEMU, VMware
      Fusion) and Ubuntu 24.04 ARM64 (VMware Fusion), image lifecycle
      (`build` / `deploy` / `tag`) and diagnostics (`status`, `list`,
      `doctor`, `watch-build`);
    - the pnpm workspace: the CLI package, the zero-dep `bridge-core`
      socket forwarder, and the guest agents (macOS LaunchAgent, Windows
      schtasks/named pipes, Ubuntu systemd) bundled into the CLI package —
      guests get the code over SFTP, never an npm install;
    - the Packer image recipes per platform, with the VNC build watchdog,
      ISO/driver staging and GHCR publishing;
    - the XDG-aware state paths (no legacy paths), the SSH agent and
      Docker bridges, and the user settings copy;
    - the docs: the CLI reference, the per-OS user guides, `AGENTS.md`,
      `DEVELOPMENT.md` and the CLI port design document.
- The GitHub Actions CI workflow (`.github/workflows/ci.yml`): runs the
  full local gate (`pnpm check`) on every push and PR, and on
  `agent-dev-env-v*` tags publishes the `agent-dev-env` npm package
  (tokenless via npm Trusted Publishers + provenance) and creates a
  GitHub release.
- The root `publish-npm` script: builds the CLI (`pnpm build`) and
  publishes `agent-dev-env` to npm in one command. The CI workflow and
  the release docs use it instead of a raw `npm publish`.
- The canary npm channel: the CI workflow now publishes a canary build
  to npm (dist-tag `canary`, version `<version>-canary.<run>.<sha>`) on
  every push to `master`, after the quality gate passes. The new
  `publish-npm:canary` root script publishes with `--tag canary`; the
  canary version is written to the CLI package only for the publish and
  is never committed.

### Changed

- Clarify in the README and the per-OS guides what each guest syncs from
  the host: every sandbox bridges the SSH agent and Docker engine, while
  the shared work directory and the user settings copy are macOS/Ubuntu
  only (Windows guests have neither). Each guide now has a "What's synced
  from the host" section.
- Rename the private workspace root package to `agent-dev-env`.
- Point the npm package metadata (`repository`, `homepage`, `bugs`) at
  the `ameshkov/agent-dev-env` repository.
- Rename the guest-side contract and the remaining references to the
  `agent-dev-env` namespace: Ubuntu systemd units and profile scripts,
  macOS launchd labels and the guest hostname, Windows scheduled tasks
  and the registered owner, the VMware working VM names, the GHCR
  artifact media types, and the docs (historical changelog entries
  included). No automatic migration — refresh the local VM state and
  images manually.
- Remove the CLI port design document (`docs/plan.md`) and its
  references — the port is complete.
- Add CI, npm, and GitHub release badges to the README.
- The `publish-npm` root script is now the single publish entry point:
  the CI workflow and DEVELOPMENT.md/AGENTS.md reference it instead of
  inline `npm publish --provenance --access public`.
- The published `agent-dev-env` npm package now ships the repo root
  `README.md` as its readme: the build step copies the root README into
  the CLI package root (npm only shows a readme from a README at the
  package root), so the npmjs page shows the same readme as the repo.
- Bump Node.js to 26 everywhere: the workspace and the published CLI
  require Node.js 26+ (`engines`), CI runs on Node 26, and the Ubuntu and
  Windows sandbox images install Node.js 26 (nvm major `26` / choco
  `26.8.1`). The macOS image already shipped Node 26.

### Fixed

- `spawnDetached()` now `unref()`s the child process: `detached: true`
  alone kept the CLI's event loop alive until the daemon exited, so
  `agent-dev-env run macos` (background mode) printed the
  "Sandbox is ready" summary and then hung instead of exiting. The
  detached processes (`tart run`, the bridge forwarders, QEMU, the
  build watchdog) keep running under their pid files as intended.
- The Docker socket discovery test no longer assumes the host has no
  `/var/run/docker.sock`: the system-wide socket candidate is injectable,
  so the suite is deterministic on GitHub's `ubuntu-latest` runners
  (which always expose that socket) instead of passing only on macOS.
