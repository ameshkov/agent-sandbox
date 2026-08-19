# Changelog

All notable changes to the macOS sandbox images.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The image version lives in the image's vars file (`image_version`); every
release bumps it and adds an entry below.

## [Unreleased]

### Changed

- The sandbox runs with no audio pass-through with the host: builds pass
  `--no-audio` to Tart, and the docs recommend `tart run --no-audio` so the
  guest can't record from the host's microphone or play sound on the host's
  speakers. No image content change — audio sharing is a runtime Tart flag,
  so existing images are unaffected.

## [1.1.0] - 2026-08-19

### Added

- OpenChamber (web UI for OpenCode, https://openchamber.dev) installed via
  `@openchamber/web` and registered as a login service (LaunchAgent) that
  listens on `0.0.0.0:3000`, so the host can open the UI at
  `http://<vm-ip>:3000`. The UI is password-protected
  (`openchamber_ui_password` in the vars file, default `sandbox`); see
  `docs/macos.md` for host access and how to change the password.

## [1.0.0] - 2026-08-19

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
