# Changelog

All notable changes to the Windows sandbox images.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The image version lives in the image's vars file (`image_version`); every
release bumps it, adds an entry below, and tags the release commit
`<platform>-v<version>` (e.g. `windows-arm64-qemu-v1.0.0`). The
`[Unreleased]` section on top is never removed — changes land there until
the next release.

## [Unreleased]

## [windows-arm64-qemu-v1.0.0] - 2026-08-23

### Added

- Windows 11 (ARM64) sandbox image (`sandbox-windows-11`), built with the
  Packer QEMU plugin on Apple Silicon (HVF accelerator). Windows 11 Pro
  ARM64 from the official Microsoft ISO (bring-your-own), installed
  unattended via `autounattend.xml` with swtpm-provided TPM 2.0 and edk2
  AAVMF UEFI firmware; the ARM64 virtio drivers (viostor/vioscsi/NetKVM)
  are staged into the unattend CD by `images/windows-arm64-qemu/build.sh`,
  which
  wraps `packer build` and also compresses the resulting qcow2 with zstd.
  `scripts/build.sh` now delegates to a platform's `build.sh` wrapper when
  one exists.
- The image ships: Chocolatey + toolchain (Node.js, Python, Git, GitHub
  CLI, ripgrep, jq, curl — versions pinned in the vars file), Visual
  Studio Code (native arm64), Chrome (Chrome for Testing snapshot,
  hash-pinned), Firefox, OpenCode, OpenCodeReview (`ocr`), the OpenChamber
  web UI as a native service on port 4000, OpenSSH Server + RDP, a Docker
  CLI client (remote engine via the host bridge), and the bridge tooling
  (`socat` + `npiperelay`) as utilities.
- `scripts/run-windows-sandbox.sh` — the user-facing Windows sandbox
  runner, landing together with the user guide `docs/windows.md`: boots
  the qcow2 under `qemu-system-aarch64` + swtpm (working VM = COW overlay
  with persistent TPM/NVRAM under `~/Library/Application Support/
  agent-sandbox/windows-11`), forwards SSH/RDP/WinRM/OpenChamber ports,
  re-enables Windows auto-logon (the image's `LogonCount=1` disables it
  after the OOBE boot) so the OpenChamber task fires at boot, and bridges
  the host's SSH agent and Docker engine into the guest: host-side socat
  on TCP 4200/4201 (loopback only) + guest-side Node relays serving the
  `\\.\pipe\openssh-ssh-agent` and `\\.\pipe\docker_engine` named pipes
  (started detached via a SYSTEM scheduled task — sshd's session job would
  kill in-session children). Docker context `host` is created and made the
  default.
- `images/windows-arm64-qemu/deploy.sh` — platform deploy wrapper that
  pushes the qcow2 to GHCR as an OCI artifact with `oras`
  (`ghcr.io/<owner>/sandbox-windows-11:<version>` + `:latest`);
  `scripts/deploy.sh` delegates to it like `build.sh` does (the macOS
  `tart push` flow cannot push a qcow2).
- Known limitations at this stage: no host-folder mount (the virtio-fs
  driver has no ARM64 Windows build) and Windows runs unactivated with a
  watermark. The sandbox agent rules (`scripts/agent-rules.md`) are
  macOS-flavored and not installed into Windows guests yet.

[unreleased]: https://github.com/ameshkov/agent-sandbox/compare/windows-arm64-qemu-v1.0.0...HEAD
[windows-arm64-qemu-v1.0.0]: https://github.com/ameshkov/agent-sandbox/releases/tag/windows-arm64-qemu-v1.0.0
