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

### Added

- `agent-dev-env stop` (windows-qemu) — stops the sandbox: qemu (via the
  runner's `qemu.pid`) and swtpm, plus the host SSH agent / Docker bridge
  listeners the runner leaves up. Honors the runner's
  `SANDBOX_AGENT_PORT` / `SANDBOX_DOCKER_PORT` overrides.
- `agent-dev-env delete` (windows-qemu) — deletes the sandbox: stops it
  first (delegating to the stop step), then removes the state dir (working
  disk overlay + TPM/EFI NVRAM + pulled image cache). Asks before deleting
  unless `--yes`.
- The virtual display is now a virtio-gpu-pci (virtio-gpu) instead of
  ramfb at runtime: the image stages the ARM64 `viogpudo` (virtio-gpu
  display-only) driver onto the unattend CD, so first logon lands it in
  the driver store and the runtime VM's virtio-gpu-pci binds it.
  Resizing the QEMU window now changes the guest's resolution
  (`VIRTIO_GPU_EVENT_DISPLAY`) instead of only scaling the framebuffer.
  The image build itself keeps ramfb (WinPE has no display driver).

### Changed

- Node.js is bumped from 22 to 26 (`nodejs_version = "26.8.1"` in the
  vars file, choco package `nodejs`).
- The image was renamed from `sandbox-windows-11` to
  `sandbox-windows-11-arm64-qemu` (vars file, template `vm_name` —
  `sandbox-windows-<windows_version>-arm64-qemu.qcow2` — the GHCR package
  name and the runner's `image_name`): the platform is now part of the
  image name, matching the state-dir naming
  (`~/Library/Application Support/agent-dev-env/windows-qemu/`).
  Older releases stay published under the old name.
- The QEMU runner (`agent-dev-env run`, windows-qemu) boots the guest
  in a resizable window: it passes `-display cocoa,zoom-to-fit=on` (the
  cocoa window is fixed-size otherwise) and replaced `-device ramfb` with
  `-device virtio-gpu-pci`. Full screen is available from the QEMU
  window's View menu → Enter Fullscreen.
- The build flow (`agent-dev-env build`) — the EXIT trap no longer prints
  `stop_watchdog: command not found` when the build aborts before the
  watchdog function is defined (it now checks before calling it).
- `agent-dev-env run` (windows-qemu) — the working VM is recreated
  when the pristine image *changes*, not just when its path changes: the
  backing marker now records path + size + mtime, and the stale overlay /
  EFI NVRAM / TPM state are discarded (previously a rebuild that replaced
  the file at the same path stacked the old overlay on the new base — a
  corrupt disk that dropped Windows to the UEFI shell). The EFI NVRAM is
  also seeded from the build output's `efivars.fd` when one exists, so
  Windows' own Boot0000 is used instead of the empty edk2 template.
- `agent-dev-env run` (windows-qemu) — the default working-VM state
  dir now lives under the CLI's data root
  (`~/Library/Application Support/agent-dev-env/windows-qemu/<image>/`):
  the platform and image are part of the path, so state from different
  platforms and images never collides. Override the data root with
  `AGENT_DEV_ENV_DATA_HOME` (or `XDG_DATA_HOME`) as before.
- `agent-dev-env run` (windows-qemu) — the summary's stop hints now
  point at `agent-dev-env stop` instead of a bare
  `kill $(cat …/qemu.pid)` and a hand-written `lsof | xargs kill` for the
  bridge listeners.

### Fixed

- The runner's guest bridge setup no longer takes ~5 min per SSH command
  on a guest whose bridges are already installed: the sshd channel does
  not close when a PowerShell payload finishes (the guest-side relays
  hold the console handles and keep trickling output, which resets
  expect's idle timeout), so every `guest_ps` call used to end only at
  an alarm (or never, before the hard alarm was added). Each remote
  command now ends with a unique sentinel echoed by the guest's shell
  after the payload exits, and expect kills the ssh client on it — step
  5 finishes in seconds.
- The image no longer depends on the Chocolatey bootstrapper persisting
  the machine PATH: the Chocolatey provisioner adds
  `C:\ProgramData\chocolatey\bin` to the Machine PATH itself and the
  toolchain + VS provisioners call `choco.exe` by its full path — the
  bootstrapper's compiled `Install-ChocolateyPath` can silently fail to
  persist in the elevated WinRM context, so after the reboot the
  re-read PATH still lacked the choco bin dir ('choco' not recognized).
  `choco cleanup` in the final verification now redirects inside `cmd`
  too, so PowerShell 5.1 never turns choco's stderr into a terminating
  error under `$ErrorActionPreference='Stop'`.
- The RemoteSigned bake-in no longer aborts the build (observed at the
  OpenChamber provisioner): the build passes `-ExecutionPolicy Bypass`
  at Process scope, so `Set-ExecutionPolicy -Scope LocalMachine`
  emitted its "overridden by a more specific scope" notice, which
  Windows PowerShell 5.1 under WinRM turned into a terminating error
  even though the machine policy was updated. The provisioner now sets
  the Process scope first (no override, no notice) and tolerates a
  failed machine-policy set.
- The image now bakes in machine-wide PowerShell `RemoteSigned` instead
  of shipping Windows' default `Restricted` policy: `opencode` (an npm
  shim — `opencode.ps1` in `%APPDATA%\npm`) refused to start in a
  PowerShell session with "running scripts is disabled on this system".
  The runners' runtime `Set-ExecutionPolicy` stays as a fallback for
  images built before this change.

## [windows-arm64-qemu-v1.1.0] - 2026-08-24

### Changed

- Build artifacts moved out of the image directory into a top-level
  `build/windows-arm64-<platform>/` directory: `output/` for
  the built qcow2, `packer_cache/` for virtio-win.iso/swtpm/watchdog
  scratch and `drivers/staging/` for the unattend CD driver subset. The
  template's `output_directory` and the staged `cd_files` path are now
  variables set by the platform `build.sh` wrapper; the macOS/tart images
  build no files and have no such directory.

### Added

- The toolchain and VS provisioners re-read PATH from the registry at
  the start of their scripts: after the tools reboot a fresh WinRM
  process can inherit a stale PATH (observed once: 'choco' not
  recognized), and the choco bootstrapper's PATH update must be picked
  up explicitly.
- The final verification checks the new toolchains with a check-and-warn
  loop instead of hard version dumps: a missing helper (e.g.
  `llvm-config`, not shipped by every LLVM Windows build) no longer
  fails the build.
- The build reboots the guest once after the virtio-win guest-tools MSI
  install (new `windows-restart` provisioner): the MSI leaves a pending
  reboot, which makes `choco install` return 3010 and makes the .NET
  Framework 4.8 Developer Pack installer fail with exit code 1 (it
  refuses to run while a reboot is pending). Choco exit-code checks in
  the VS phase accept 3010 (success, reboot required).
- Toolchains from AdGuard's `build-agent-images` Windows image
  (`windows2022-vs2022` / `windows2022-go`) that were missing: Go, Rust
  (via rustup — arm64 host toolchain + MSVC targets for
  x86_64/i686/aarch64), Visual Studio 2022 Build Tools (choco package +
  `setup.exe` finalizer: .NET 4.8/.NET Core SDKs, VC++ workload
  x86/x64/ARM/ARM64, CMake, Windows 11 SDK 22621), WiX Toolset, protoc,
  NASM, LLVM, Vim, NuGet CLI, MinGW-w64 and GNU make. All versions are
  pinned in the vars file (`go_version`, `rust_version`,
  `vs_buildtools_version`, `wixtoolset_version`, `protoc_version`,
  `nasm_version`, `llvm_version`, `vim_version`, `nuget_version`,
  `mingw_version`, `make_version`); the toolchain provisioner and the
  final verification dump their versions.
- Build watchdog: `scripts/watch-build.sh` (+ `watch-build.py` supervisor
  and `watch-build-ocr.swift` OCR helper). The headless build's
  boot-command Enter-spam can hit "Cancel" on Windows Setup's "Installing
  Windows 11" screen, and boot races can land in the UEFI shell — either
  way the build stalls until something answers. The watchdog polls the
  VNC framebuffer the Packer plugin exposes (pinned to port 5901 in the
  template), OCRs each frame with Apple Vision, and auto-dismisses the
  quit dialog (clicking "No" at the OCR'd button position), answers the
  "Press any key to boot from CD or DVD" prompt, and boots the ISO from
  the UEFI shell. `build.sh` starts it around `packer build` and stops it
  in the cleanup trap; skipped with a warning when `vncdotool` or the
  Xcode command line tools are missing. Observed during the v1.0.0 build:
  one cancel dialog dismissed, one EFI-shell boot rescued.

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
- `scripts/run-windows-qemu-sandbox.sh` — the user-facing Windows sandbox
  runner, landing together with the user guide `docs/windows-qemu.md`: boots
  the qcow2 under `qemu-system-aarch64` + swtpm (working VM = COW overlay
  with persistent TPM/NVRAM under `~/Library/Application Support/
  agent-dev-env/windows-11`), forwards SSH/RDP/WinRM/OpenChamber ports,
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

[unreleased]: https://github.com/ameshkov/agent-dev-env/compare/windows-arm64-qemu-v1.1.0...HEAD
[windows-arm64-qemu-v1.1.0]: https://github.com/ameshkov/agent-dev-env/releases/tag/windows-arm64-qemu-v1.1.0
[windows-arm64-qemu-v1.0.0]: https://github.com/ameshkov/agent-dev-env/releases/tag/windows-arm64-qemu-v1.0.0
