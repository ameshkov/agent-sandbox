# Changelog

All notable changes to the macOS sandbox images.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The image version lives in the image's vars file (`image_version`); every
release bumps it, adds an entry below, and tags the release commit
`<platform>-v<version>` (e.g. `mac-v1.2.0`). The `[Unreleased]` section on top
is never removed — changes land there until the next release.

## [Unreleased]

### Added

- `scripts/run-macos-sandbox.sh` now offers to copy the host's user settings
  into the guest — opencode config (`~/.config/opencode/opencode.json` /
  `.jsonc`) and auth (`~/.local/share/opencode/auth.json`), plus
  `~/.ssh/allowed_signers`, `~/.ssh/known_hosts`, `~/.ssh/*.sh` and
  `~/.gitconfig` — once per VM, tracked by a versioned marker inside the
  guest (`~/.config/agent-sandbox/settings-copied`); bumping the settings
  version in the script re-copies when new settings are added. Skip with
  `--no-settings`.

### Changed

- The template's `disk_size` default is now 160 GB (matching the vars files
  and the built images) — the previous 80 GB default was below the ~140 GB
  Cirrus base image disk, and tart can only grow a disk, never shrink it. No
  effect on released images; only relevant when a vars file omits `disk_size`.

## [mac-v1.2.0] - 2026-08-19

### Added

- Google Chrome and Mozilla Firefox (latest stable universal macOS builds)
  installed via Homebrew casks; the quarantine attribute is stripped so they
  launch without Gatekeeper prompts — the VM boots straight to the desktop
  and may run headless.

### Changed

- The OpenChamber LaunchAgent now runs the exact `opencode` binary the image
  ships: the build resolves `command -v opencode` and pins the absolute path
  via `OPENCODE_BINARY` before `openchamber startup enable` snapshots the
  environment, instead of relying on PATH lookup in the login session.
  Rebuilding the image is required for this to take effect.
- The sandbox runs with no audio pass-through with the host: builds pass
  `--no-audio` to Tart, and the docs recommend `tart run --no-audio` so the
  guest can't record from the host's microphone or play sound on the host's
  speakers. No image content change — audio sharing is a runtime Tart flag,
  so existing images are unaffected.

## [mac-v1.1.0] - 2026-08-19

### Added

- OpenChamber (web UI for OpenCode, https://openchamber.dev) installed via
  `@openchamber/web` and registered as a login service (LaunchAgent) that
  listens on `0.0.0.0:3000`, so the host can open the UI at
  `http://<vm-ip>:3000`. The UI is password-protected
  (`openchamber_ui_password` in the vars file, default `sandbox`); see
  `docs/macos.md` for host access and how to change the password.

## [mac-v1.0.0] - 2026-08-19

First versioned release of the `sandbox-macos-tahoe` image (macOS 26 Tahoe +
Xcode 26.4.1).

### Added

- System setup: auto-login as `admin`/`admin`, Remote Login (SSH), Screen
  Sharing (VNC), friendly hostname, Tart Guest Agent check.
- Homebrew toolchain: `bash`, `git`, `gh`, `jq`, `ripgrep`, `coreutils`,
  `curl`, `wget`, `socat`, `nvm`, `python@3.14`, `ruby`.
- Node.js 26 installed via nvm (default version, includes npm).
- Unversioned `python`/`pip` aliases pointing at `python@3.14`.
- Visual Studio Code (latest stable) with the `code` CLI on PATH.
- OpenCode (AI coding agent) via the anomalyco Homebrew tap.

[unreleased]: https://github.com/ameshkov/agent-sandbox/compare/mac-v1.2.0...HEAD
[mac-v1.2.0]: https://github.com/ameshkov/agent-sandbox/releases/tag/mac-v1.2.0
[mac-v1.1.0]: https://github.com/ameshkov/agent-sandbox/releases/tag/mac-v1.1.0
[mac-v1.0.0]: https://github.com/ameshkov/agent-sandbox/releases/tag/mac-v1.0.0
