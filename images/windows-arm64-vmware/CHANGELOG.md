# Changelog

All notable changes to the Windows sandbox images (VMware).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The image version lives in the image's vars file (`image_version`); every
release bumps it, adds an entry below, and tags the release commit
`<platform>-v<version>` (e.g. `windows-arm64-vmware-v1.0.0`). The
`[Unreleased]` section on top is never removed — changes land there until
the next release.

## [Unreleased]

### Added

- `agent-dev-env stop` (windows-vmware) — stops the sandbox:
  `vmrun -T fusion stop` on the working VM (graceful via VMware Tools with
  a hard power-off fallback), plus the host SSH agent / Docker bridge
  listeners the runner leaves up. Honors the runner's
  `SANDBOX_AGENT_PORT` / `SANDBOX_DOCKER_PORT` overrides.
- `agent-dev-env delete` (windows-vmware) — deletes the sandbox: stops
  it first (delegating to the stop step), then removes the state dir
  (extracted pristine base + working clone + pulled image cache). Asks
  before deleting unless `--yes`.
- The toolchain and VS provisioners re-read PATH from the registry at
  the start of their scripts: after the tools reboot a fresh WinRM
  process can inherit a stale PATH (observed once: 'choco' not
  recognized), and the choco bootstrapper's PATH update must be picked
  up explicitly.
- The final verification checks the new toolchains with a check-and-warn
  loop instead of hard version dumps: a missing helper (e.g.
  `llvm-config`, not shipped by every LLVM Windows build) no longer
  fails the build.
- The build reboots the guest once after the VMware Tools install (new
  `windows-restart` provisioner): the tools installer leaves a pending
  reboot, which makes `choco install` return 3010 (observed on python)
  and makes the .NET Framework 4.8 Developer Pack installer fail with
  exit code 1 (it refuses to run while a reboot is pending). Choco
  exit-code checks in the VS phase accept 3010 (success, reboot
  required).
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

### Changed

- The image was renamed from `sandbox-windows-11-vmware` to
  `sandbox-windows-11-arm64-vmware` (vars file, template `vm_name` —
  `sandbox-windows-<windows_version>-arm64-vmware` — the GHCR package
  name, the runner's `image_name` and the working VM's display name):
  the platform is now part of the image name, matching the state-dir
  naming (`~/Library/Application Support/agent-dev-env/windows-vmware/`).
  Older releases stay published under the old name.
- Build artifacts moved out of the image directory into a top-level
  `build/windows-arm64-<platform>/` directory: `output/` for
  the built vmx + vmdk + nvram, `packer_cache/` for watchdog scratch and
  `drivers/staging/` for the unattend CD vmxnet3 driver. The template's
  `output_directory` (and the `cd_files` staging path) are now variables
  set by the CLI build flow; the macOS/tart images build no
  files and have no such directory. Guest content is unchanged (no
  `image_version` bump).
- The build output is upgraded post-build with `vmrun upgradevm`
  (the CLI build flow): the vmware-iso builder writes
  the VM at hardware version 20, and a newer Fusion first starts such a VM
  with a one-time "Upgrade this virtual machine?" prompt (the headless
  build never sees it; the first GUI start does). The published artifact
  now carries the hardware version the building Fusion supports (22 on
  Fusion 26). The shared helper lives in `lib/vmrun.ts`.
- `agent-dev-env run` (windows-vmware) upgrades its working clone the
  same way (once per clone, recorded next to the vmx in
  `working/.hw-version`), so artifacts built by older Fusion versions also
  start without the prompt.
- The guest-side bridge scripts (the Node relay, the idempotent
  `bridges.ps1`, the `start-relays.cmd` bootstrap and the
  `guest-setup.ps1` installer) moved out of the runner's heredocs into
  the bundled `packages/guest-agent-windows` agent: the agent
  renders them for the run's bridge ports + host alias and writes each
  one into the guest with its own small SSH exec (one combined payload
  overran the Windows OpenSSH exec-request command line); the guest only
  rewrites a file when its content changed.
- `agent-dev-env run` (windows-vmware) — the default working-VM state
  dir now lives under the CLI's data root
  (`~/Library/Application Support/agent-dev-env/windows-vmware/<image>/`):
  the platform and image are part of the path, so state from different
  platforms and images never collides. Override the data root with
  `AGENT_DEV_ENV_DATA_HOME` (or `XDG_DATA_HOME`) as before.
- `agent-dev-env run` (windows-vmware) — the working clone now gets a
  distinct display name, `agent-sandbox-windows-11-arm64-vmware` (set in
  the cloned vmx before the first start), instead of inheriting the
  pristine image's `sandbox-windows-11-arm64-vmware`: `vmrun clone`
  copies the source vmx's `displayName`, so before this the working VM
  was indistinguishable from the base in Fusion's VM library.
- `agent-dev-env run` (windows-vmware) — the summary's stop hints now
  point at `agent-dev-env stop` instead of a bare
  `vmrun stop` and a hand-written `lsof | xargs kill` for the bridge
  listeners.
- HGFS shared folders are not supported for Windows 11 ARM guests on
  Apple silicon (VMware Tools for Windows Arm ships no HGFS kernel
  driver, so the guest can never mount `\\vmware-host\Shared Folders`
  even though the host publishes the share). The runner now detects the
  unsupported combo from the vmx `guestos` string and skips the share
  with a warning instead of registering it and claiming success; the
  summary reports `Shared: not supported (...)`.
  `SANDBOX_WORK_DIR` / `--work-dir` stay accepted but are a no-op with a
  warning. `docs/windows-vmware.md` and the image README now state the
  limitation and the working alternatives (SMB share from the Mac,
  SSH/SCP, RDP clipboard, git, OpenChamber UI).

### Fixed

- The runner's guest bridge setup no longer takes ~5 min per SSH command
  on a guest whose bridges are already installed: the sshd channel does
  not close when a PowerShell payload finishes (the guest-side relays
  hold the console handles and keep trickling output, which resets
  expect's idle timeout), so every `guest_ps` call used to end only at
  the 5-min alarm. Each remote command now ends with a unique sentinel
  echoed by the guest's shell after the payload exits, and expect kills
  the ssh client on it — step 5 finishes in seconds.
- The shared host directory no longer fails right after the auto-logon
  reboot — the runner (`agent-dev-env run`, windows-vmware) called
  `vmrun addSharedFolder`
  as soon as sshd answered, but VMware Tools can still be starting then:
  `getGuestIPAddress`/sshd were already up while the tools state vmrun
  needs for the HGFS registration was not, so the runner logged `Error:
  The VMware Tools are not running in the virtual machine` and the share
  never appeared in the guest at
  `\\vmware-host\Shared Folders\work`. The runner now waits for
  `vmrun checkToolsState` to report `running` (up to 5 min) and
  retries `addSharedFolder` a few times, then warns only if it still
  failed. A share persisted by a previous run (`Error: Already exists`)
  is treated as success.
- The image no longer depends on the Chocolatey bootstrapper persisting
  the machine PATH: the Chocolatey provisioner adds
  `C:\ProgramData\chocolatey\bin` to the Machine PATH itself and the
  toolchain + VS provisioners call `choco.exe` by its full path — the
  bootstrapper's compiled `Install-ChocolateyPath` can silently fail to
  persist in the elevated WinRM context, so after the reboot the
  re-read PATH still lacked the choco bin dir ('choco' not recognized).
  The toolchain retry loop also stops redirecting native stderr with
  `2>&1`: under `$ErrorActionPreference='Stop'` in Windows PowerShell
  5.1 that turns the not-found message into an immediate terminating
  error before the retry logic could run. The loop still goes through
  `cmd /c` so the package name and its `--version` stay separate
  arguments (a direct `& $choco install $installArgs` passed
  'nodejs --version=…' as one argument, which choco treated as a package
  name). `choco cleanup` in the final verification now redirects inside
  `cmd` for the same stderr reason.
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
- VMware Tools are now actually working in the image — the runnable
  regression the sandbox runner was hitting: the ARM64 tools package
  (Fusion's `windows.iso`) ships no VMCI driver (only `vmxnet3` +
  `vm3d` + `vmusbmouse`), so the tools installer skips its own service
  registration and the image landed with `vmtoolsd.exe` present but no
  'VMware Tools' service. The runner then hung for 15 min at "Waiting
  for the guest IP (VMware Tools; up to 15 min)" — vmrun
  `getGuestIPAddress` answered "The VMware Tools are not running in the
  virtual machine", and the runner (correctly) refused to treat that as
  an IP. The final verification now registers the 'VMware Tools'
  service itself (auto-start, if absent) and starts it, and fails the
  build when the service is still not running — instead of checking
  only for `vmtoolsd.exe` with `Test-Path` (which passed for the broken
  install).
- The VMware Tools service registration lives in a provisioner, not in
  `autounattend.xml`'s FirstLogonCommands: the first attempt (baking
  the `New-Service` + `Start-Service` block into the tools-install
  CommandLine, ~1 KB of extra text) broke Windows Setup at the first
  boot — the guest showed "Windows could not complete the installation.
  To install Windows on this computer, restart the installation." and
  Packer spun on "Waiting for WinRM" until the 90 m timeout. The setup
  logs (C:\Windows\Panther) show the failure at the Pre-OOBE phase
  (windeploy 0x80220005 → rollback; also a BFSVC EFI boot-file
  `BfspCopyFile` 0x3 storm) — the oobeSystem pass never finished, so
  neither the OOBE nor FirstLogonCommands (network driver, tools,
  WinRM) ever ran. The tools CommandLine is back to the proven shorter
  form; the service registration moved to the final-verification
  provisioner.
- The final verification's fail-hard `throw` message is ASCII-only:
  the original em-dash (`—`) inside the inline PowerShell string was
  mangled in the Packer WinRM transfer (it came back as a smart-quote
  byte, which closed the string literal early and made the parser fail
  with "Unexpected token 'vmtoolsd.exe'" plus a misleading "Missing
  closing '}'"/"Try statement is missing its Catch or Finally block" —
  the build aborted at 47 min in the last provisioner). Non-ASCII in
  inline PowerShell string literals is now documented as a gotcha in
  `AGENTS.md`; comments are unaffected.

## [windows-arm64-vmware-v1.0.0] - 2026-08-23

### Added

- Windows 11 (ARM64) VMware sandbox image (`sandbox-windows-11-vmware`),
  built with the Packer vmware-iso plugin on Apple Silicon (VMware Fusion
  hosts the installer — the most proven Windows-ARM path; Fusion provides
  the ARM64 vmxnet3 NIC driver, the ARM64 VMware Tools and NVMe storage
  with the in-box driver). Windows 11 Pro ARM64 from the official
  Microsoft ISO (bring-your-own; the same 25H2 ISO checksum the QEMU
  image pins), installed unattended via `autounattend.xml` with the
  Windows-11 hardware-check bypasses (BypassCPUCheck is mandatory —
  Apple Silicon) and OOBE bypasses. The build stages the vmxnet3 driver
  from Fusion's `Contents/Library/isoimages/arm64/drivers-arm64.zip` into
  the unattend CD (no in-box VMware NIC driver: it must land before any
  network use) and installs Fusion's ARM64 tools ISO (attached by the
  builder, `tools_mode "attach"`; installed by `autounattend.xml` at
  first logon, before WinRM — the tools installer rebinds the NIC and
  kills any live WinRM session (a provisioner-based install timed out).
- The image ships the same toolchain as the QEMU image: Chocolatey +
  toolchain (Node.js, Python, Git, GitHub CLI, ripgrep, jq, curl —
  versions pinned in the vars file), Visual Studio Code (native arm64),
  Chrome (Chrome for Testing snapshot, hash-pinned), Firefox, OpenCode,
  OpenCodeReview (`ocr`), the OpenChamber web UI as a native service on
  port 4000, VMware Tools, OpenSSH Server + RDP, a Docker CLI client
  (remote engine via the host bridge), and the bridge tooling
  (`socat` + `npiperelay`) as utilities.
- `images/windows-arm64-vmware/build.sh` — platform build wrapper:
  verifies the host + Fusion install + ISO sha256, stages the vmxnet3
  driver, starts the VNC build watchdog (shared `scripts/watch-build.sh`),
  and runs `packer init` + `packer build`.
- `images/windows-arm64-vmware/deploy.sh` — platform deploy wrapper that
  packs the output directory (vmx + vmdk + nvram) into a tar.gz and
  pushes it to GHCR as an OCI artifact with `oras`
  (`ghcr.io/<owner>/sandbox-windows-11-vmware:<version>` + `:latest`);
  `scripts/deploy.sh` delegates to it like it does for the QEMU image.
- `scripts/run-windows-vmware-sandbox.sh` — the user-facing VMware sandbox
  runner, landing together with the user guide `docs/windows-vmware.md`:
  extracts the archive into the state dir and clones a working VM with
  `vmrun -T fusion clone ... full` (base never written to) under
  `~/Library/Application Support/agent-sandbox/windows-11-vmware`, boots
  it with `vmrun start`, discovers the guest IP via `vmrun
  getGuestIPAddress` (VMware Tools are in the image — no port
  forwarding, the host is the NAT router for the vmnet8 subnet),
  re-enables Windows auto-logon (the image's `LogonCount=1` disables it
  after the OOBE boot) so the OpenChamber task fires at boot, bridges the
  host's SSH agent and Docker engine into the guest (host-side socat on
  TCP 4200/4201 bound to the vmnet8 address + guest-side Node relays
  serving the `\\.\pipe\openssh-ssh-agent` and `\\.\pipe\docker_engine`
  named pipes, started detached via a SYSTEM scheduled task), optionally
  shares a host directory (HGFS, `--work-dir`), and verifies OpenChamber.
- Known limitations at this stage: Windows runs unactivated with a
  watermark; the sandbox agent rules (`scripts/agent-rules.md`) are
  macOS-flavored and not installed into Windows guests yet; the shared
  folder is best-effort (HGFS must be enabled by VMware Tools).

[unreleased]: https://github.com/ameshkov/agent-sandbox/compare/windows-arm64-vmware-v1.0.0...HEAD
[windows-arm64-vmware-v1.0.0]: https://github.com/ameshkov/agent-sandbox/releases/tag/windows-arm64-vmware-v1.0.0
