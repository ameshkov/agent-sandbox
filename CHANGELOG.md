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
    - the XDG-aware state paths (no legacy `agent-sandbox` paths), the SSH
      agent and Docker bridges, and the user settings copy;
    - the docs: the CLI reference, the per-OS user guides, `AGENTS.md`,
      `DEVELOPMENT.md` and the CLI port design document.

### Fixed

- `spawnDetached()` now `unref()`s the child process: `detached: true`
  alone kept the CLI's event loop alive until the daemon exited, so
  `agent-dev-env run macos` (background mode) printed the
  "Sandbox is ready" summary and then hung instead of exiting. The
  detached processes (`tart run`, the bridge forwarders, QEMU, the
  build watchdog) keep running under their pid files as intended.
