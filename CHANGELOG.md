# Changelog

All notable changes to the `agent-dev-env` CLI and the repo tooling.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The CLI version lives in `package.json`; image versions live in the
per-image vars files (`image_version`) and are recorded in the per-image
changelogs (`images/<platform>/CHANGELOG.md`). The `[Unreleased]` section
on top is never removed — changes land there until the next release.

## [Unreleased]

### Added

- New TypeScript CLI (`agent-dev-env`, npm-published) replacing the shell
  scripts phase by phase: `src/` layout (`cli.ts`, `commands/`,
  `lifecycle/`, `lib/`), commander surface declared for all commands,
  `list` / `status` / `doctor` implemented. Shared foundations ported
  from the shell scripts: colored logger, `confirm()` prompt, vars-file
  parsing, `{{TOKEN}}` template rendering, GHCR owner resolution, XDG-aware
  paths, process helpers (`run`/`spawnDetached`/`killTree`/`withTimeout`),
  platform registry, vmrun resolution, image catalog.
- Toolchain: switched to pnpm (packageManager, lockfile), mirroring the
  ameshkov/mcp-compress-router checks — oxlint (correctness category +
  max-lines/max-lines-per-function), Prettier, Markdownlint, Knip
  unused-export analysis, husky pre-commit hook, and the `pnpm check`
  full gate (format:check → lint → typecheck → build → test).
- Tests co-located with sources (`src/**/*.test.ts`), Vitest config
  matching the reference repo (`globals: true`).
- `AGENTS.md` rewritten in the reference repo's structure (overview,
  technical context, structure, commands, contribution rules, code
  guidelines incl. testing/dependency management, project conventions).
- `docs/plan.md` — the design document for the CLI port: CLI surface,
  paths policy, project layout, shared module dedup, runner framework,
  lifecycle commands, release flow, implementation phases with current
  progress, risks, and out-of-scope notes.
- The CLI moved into the workspace: `packages/agent-dev-env-cli`
  (published as `agent-dev-env`), root `package.json` becomes a private
  workspace root with the shared tooling; `tsconfig.base.json` holds the
  compiler options; build output + bundled guest artifacts now live in
  `packages/agent-dev-env-cli/dist/`. Lint/format ignores are depth-aware
  (`**/node_modules/**`, `**/dist/**`) for the nested package dirs.
- Workspace + guest agents (Phase 2): `pnpm-workspace.yaml` with
  `packages/bridge-core` (zero-dep forwarder: `unix:`/`pipe:`/`tcp:`
  endpoints, per-connection dial, stale-socket handling, probe helper;
  host CLI entry `bin.ts`), `packages/guest-rules` (agent rules
  probe/apply with the sha256 marker semantics), and the guest agents
  `guest-agent-mac` (launchd, zprofile/ssh config blocks),
  `guest-agent-windows` (schtasks, named pipes, user env, docker
  context; shared by QEMU + VMware) and `guest-agent-ubuntu` (systemd
  user units, profile.d). All workspace-internal: bundled by esbuild
  into `dist/assets/` single-file JS in `copy-assets.mjs` and SFTP'd
  into guests — no npm install inside guests.
- macOS runner (Phase 3): the shared run framework
  (`runners/framework.ts` — step order, RunContext/RunState, host
  preflight) and the macOS backend (`runners/macos.ts` +
  `macos-bridges.ts` + `macos-guest.ts` + `macos-rules.ts` +
  `macos-summary.ts`) — the shell flow ported section-for-section:
  image pull (GHCR owner via `ghcr.ts`) + clone, boot with the
  recommended settings (`tart set`/`run`, foreground, background + log),
  host bridges = detached `dist/assets/bridge/bridge.js` per role with
  pidfiles (no socat), guest wiring = the bundled
  `guest-agent-mac.js` uploaded over `tart exec` + `install` + `status`
    - `docker info` verification, agent rules probe/confirm/apply, user
  settings copy (version-marker gated), OpenChamber verify, summary.
  `run`/`stop`/`delete`/`sync` are implemented for `macos` (other
  platforms keep the later-phase placeholder).
- `lib/tart.ts` — the tart wrappers (list/ip/clone/set/run/stop/delete/
  exec/pull) + pure arg/parse builders (reused by `status`).
- `settings/macos.ts` + `settings/macos-copy.ts` — the macOS user
  settings copy (collection, .gitconfig host-home sanitization, tar
  stream over `tart exec`, version marker under
  `~/.config/agent-dev-env/`, OpenChamber restart) — port of
  `scripts/lib/macos-settings.sh`, shared by the run step and `sync`.
- `assets/rules/` — the agent rules content (macOS + Linux) moved out
  of `scripts/` into the bundled runtime assets.
- `guest-agent-mac`: `install` now reloads the launchd jobs (idempotent
  reinstall with fresh args) and sets up the docker `host` context; the
  launchd plists embed the resolved docker socket path (launchd does not
  expand `$HOME`); `doctor` drops the socat check (the Node forwarder
  replaced socat everywhere).
- Ubuntu VMware runner (Phase 4): the ssh2 transport (`lib/ssh.ts` —
  password auth, host-key skip, exec with stdin payload + watchdog,
  SFTP uploads, `waitForSshd` with the auth-error probe semantics) and
  the full vmrun helper set (`lib/vmrun.ts` — start/stop/graceful-stop,
  clone, bounded `getGuestIPAddress`/`checkToolsState`, `upgradevm`
  (never exits — 180 s cap), vmx hardware-version + displayname
  parsers, shared-folder add/enable) + the NAT host-alias resolution
  (`lib/network.ts` — ifconfig /24 scan with the x.y.z.1 fallback,
  since Fusion's NAT gateway is vmnetd's x.y.z.2). The Ubuntu backend
  (`runners/ubuntu.ts` + `ubuntu-image.ts` + `ubuntu-shared.ts` +
  `ubuntu-bridges.ts` + `ubuntu-guest.ts` + `ubuntu-rules.ts` +
  `ubuntu-summary.ts`) ports the shell flow: image select
  (`UBUNTU_VMWARE_IMAGE` → local build output → cached → oras pull),
  base extraction with the `path|size|mtime` identity marker, working
  clone + display name + one-time hardware upgrade, boot with the
  guest-IP/sshd waits, HGFS shared folder, the NAT-segment bridges +
  the bundled `guest-agent-ubuntu.js` upload/install/status over ssh2,
  the Linux agent rules (`agent-rules-linux.md` + `{{NAT_GATEWAY}}`),
  and the user-settings copy over ssh2 (`settings/ubuntu.ts` +
  `ubuntu-copy.ts` — version 3, /home/admin, VS Code +
  mcp-compress-router path mapping, tar.gz over SFTP). `run`/`stop`/
  `delete`/`sync` are implemented for `ubuntu-vmware` too (only the
  Windows backends keep the later-phase placeholder).
- Windows VMware runner (Phase 5): the PowerShell transport over ssh2 —
  `lib/ssh.ts` gained the completion-sentinel exec (the Windows OpenSSH
  channel never closes on its own once the guest relays hold the console
  handles; the shell's `echo $sentinel` + kill-ssh-client trick) and
  `runners/windows-guest.ts` runs snippets via UTF-16LE base64
  `-EncodedCommand` (the expect `guest_ps` port, incl. the
  credentials from `winrm_username`/`winrm_password` +
  `WINDOWS_PASSWORD`). The Windows backend (`runners/windows.ts` +
  `windows-image.ts` + `windows-bridges.ts` + `windows-autologon.ts` +
  `windows-shared.ts` + `windows-summary.ts`) ports the shell flow:
  image select (`WINDOWS_VMWARE_IMAGE` → local build output → cached →
  oras pull), base extraction + working clone + display name + one-time
  hardware upgrade (shared `vmware-image.ts` with the Ubuntu backend),
  boot with the guest-IP/sshd waits + the one-time auto-logon (registry
  probe → enable + reboot), HGFS detection (VMware Tools for Windows Arm
  ships no driver — skipped with a warning), the NAT-segment bridges +
  the bundled `guest-agent-windows.js` upload/install/status over ssh2 +
  `docker info` verification, OpenChamber verify, summary.
  `run`/`stop`/`delete` are implemented for `windows-vmware`.
- `lib/qemu.ts` — the Windows QEMU host-side helpers: the working-VM
  state paths (`<data>/windows-qemu/<image>/working/` — overlay,
  `efivars.fd`, `tpm/`, pidfiles, sockets), the backing-image identity
  marker (`path|size|mtime`, so a rebuild over the same path drops the
  stale overlay), the exact `launch_qemu` args builder (virt/HVF/AAVMF
  UEFI, swtpm TPM 2.0 with `ppi=off`, virtio-gpu-pci, xhci + keyboard +
  tablet, user-mode networking with the SSH/RDP/OpenChamber/WinRM
  hostfwd, `cocoa,zoom-to-fit=on` display) and the swtpm/qemu process
  management (pidfiles, stale-process kills, the overlay-path pgrep
  fallback).
- Windows QEMU runner (Phase 6): the backend (`runners/windows-qemu.ts`,
  `qemu-image.ts`, `windows-qemu-summary.ts`) ports the shell flow —
  image select (`WINDOWS_IMAGE` → local build output → cached → oras
  pull ~14 GB), COW overlay + TPM + EFI NVRAM creation, boot with the
  qemu-alive `waitForSshd` (hostfwd probe semantics: the listener binds
  before the guest boots), the one-time auto-logon (the registry
  check/enable moved into `configureAutologon` in `windows-autologon.ts`
  behind a callback-shaped reboot wait the QEMU flow targets at the fixed
  hostfwd), the hostfwd bridges (`windows-bridges.ts` resolves the
  guest-visible alias `10.0.2.2` + the `127.0.0.1` bind for QEMU vs the
  NAT-segment alias for VMware) + the same
  `guest-agent-windows.js` upload/install/status over ssh2 + `docker
  info` verification, OpenChamber verify on `http://127.0.0.1:4000`,
  summary. `run`/`stop`/`delete` are implemented for `windows-qemu` too
  (all four platforms' runners are green; `sync` keeps its helpful
  error for Windows — no settings step).
- `run` option resolution gained the forwarded ports
  (`SANDBOX_SSH_PORT`/`SANDBOX_RDP_PORT`/`SANDBOX_WINRM_PORT`, default
  2222/3389/5985 for `windows-qemu`), and `runners/windows-guest.ts`
  parameterizes the guest sshd port (VMware reaches guest 22 directly,
  QEMU the hostfwd port); `doctor` now checks `oras` for `windows-qemu`
  (the default path is the GHCR pull).
- `runners/vmware-common.ts` — the run-time helpers shared by the two
  VMware backends (vmrun prereq, stop-running-VM restart flow, bounded
  guest-IP/Tools waits, shared-folder add with the "Already exists"
  case, foreground stop-wait + bridge cleanup); the Ubuntu backend
  `runners/ubuntu-*.ts` was refactored to use them.
- `guest-agent-windows` `install` now starts the bridge relays right
  away (the ONLOGON tasks fire only at the next logon): a SYSTEM ONCE
  task (`agent-sandbox-relays`, the legacy `start-relays.cmd` detach
  mechanism) is written + run via `schtasks /Run`; `uninstall` removes
  it. The `start-relays.cmd` content is a pure builder
  (`relayStartCommand`) in `schtasks.ts`, with co-located tests.
- Image lifecycle (Phase 7) — `build` / `deploy` / `tag` /
  `watch-build` implemented, completing the CLI surface:
    - `lifecycle/build.ts` (the dispatcher) + the four flows
      (`build-macos.ts`, `build-qemu.ts`, `build-windows-vmware.ts`,
      `build-ubuntu.ts`): macOS uses the plain packer init/build path;
      windows-qemu stages the ISO + ARM64 virtio drivers (hdiutil),
      runs swtpm, wraps packer's qemu binary with `qemu-with-tpm.sh`,
      runs the VNC watchdog, and zstd-compresses the qcow2;
      windows-vmware stages the vmxnet3 trio from Fusion's
      drivers-arm64.zip and upgrades the artifact's hardware version;
      ubuntu-vmware serves the autoinstall seed on port 8004, types the
      grub command via the watchdog (vmnet8 subnet from Fusion's
      dhcpd.conf). Shared logic in `lifecycle/build-shared.ts` (host
      prereqs, `<data>/build/<platform>/` layout, SHA256 verification,
      materialized `<data>/build-context/<platform>/` packer context,
      packer init/fmt/build pipeline, pure arg builders) and
      `lifecycle/build-watchdog.ts` (vncdotool/swiftc checks with
      warn+skip, OCR helper compiled if-stale, detached
      `watch-build.py` spawn with watchdog.log + stop). `--force` →
      `packer -force`; `--no-watchdog` skips the watchdog.
    - `lifecycle/deploy.ts`: macOS pushes with
      `tart push --chunk-size 3` (version and latest); the qcow2 pushes
      via `oras push` as the `application/vnd.agent-sandbox.qcow2`
      artifact; the VMware pair gets packed into a tar.gz (vmx, nvram,
      vmdk — logs excluded) and pushed as
      `application/vnd.agent-sandbox.vmware-vm`. Owner resolution
      (GHCR_OWNER → `--owner` → git remote → `ameshkov`) stays in
      `lib/ghcr.ts`.
    - `lifecycle/tag.ts` + `lib/git.ts` release-tag helpers: annotated
      `<platform-dir>-v<image_version>` tag with the shell's gates
      (clean worktree + index, tag-not-exists, `## [<tag>]` CHANGELOG
      entry), pushed to origin; `--repo` overrides the checkout.
    - `watch-build` (hidden) runs the bundled `assets/watchdog/`
      `watch-build.py` in the foreground with the compiled-if-stale
      Apple Vision OCR helper (hard errors for missing vncdotool/swiftc,
      like `watch-build.sh`).
- `assets/watchdog/` — `watch-build.py` + `watch-build-ocr.swift` now
  ship inside the npm package (copy-assets bundles `assets/**`), so
  builds from an npm install get the watchdog without the repo scripts.

- `docs/cli.md` — the CLI reference: installation, command overview
  (`run`/`stop`/`delete`/`sync`/`status`/`list`/`build`/`deploy`/`tag`/
  `doctor`/`watch-build`), the per-platform defaults table, the full
  environment-variable list and the XDG paths policy. It absorbs the four
  "Runner script reference" sections of the platform guides.

### Changed

- `tsconfig.json` split into `tsconfig.app.json` (build) +
  `tsconfig.test.json` (tests, noEmit), like the reference repo.
- All dependency versions pinned exactly (no `^`/`~`).
- README rewritten around the `agent-dev-env` npm CLI: `npx
  agent-dev-env doctor`/`run` quickstart, links to the CLI reference.
- Per-platform guides (`docs/macos.md`, `docs/ubuntu-vmware.md`,
  `docs/windows-qemu.md`, `docs/windows-vmware.md`) migrated:
  `./scripts/*-sandbox.sh` → `agent-dev-env run|stop|delete|sync
  <platform>`; state paths now the `agent-dev-env` XDG roots (no legacy
  `agent-sandbox` paths); the runner-script-reference sections point at
  `docs/cli.md`; bridge descriptions updated for the built-in forwarder
  (no socat).
- `docs/ssh-agent.md` rewritten for the built-in bridge: the CLI detects
  an overridden host agent socket and sets up host `bridge.js` +
  per-platform guest agents (no socat install, no manual heredocs).
- `DEVELOPMENT.md` migrated: `build`/`deploy`/`tag` via the CLI, build
  outputs under `<data>/build/<platform>/`, watchdog from
  `assets/watchdog/`, repository layout tree updated.
- Per-image `images/*/README.md` and template/vars comments: build,
  publish and tag commands now `agent-dev-env ...`; the build watchdog is
  the bundled asset (not `scripts/watch-build.sh`).
- `AGENTS.md` structure/build-command sections updated for the completed
  port (the legacy shell scripts are gone).
- `knip.config.ts`: dropped the stale `ignoreDependencies` entry for
  `ssh2`/`@types/ssh2` — the ssh2 transport landed in Phase 4.

### Removed

- The legacy shell tooling: `scripts/` (per-platform runners,
  `stop`/`delete`/`sync`, `build.sh`/`deploy.sh`/`tag.sh`,
  `watch-build.{sh,py}` + `watch-build-ocr.swift`,
  `agent-rules{,-linux}.md`, `lib/`) and the platform wrappers
  `images/*/{build,deploy}.sh`. The watchdog + rules live in `assets/`;
  `qemu-with-tpm.sh` stays as the qemu build flow's runtime asset.

### Fixed

- `stop`/`delete` dropped the unreachable `notYet` fallback — all four
  platforms are handled upstream (the fallback only remained reachable for
  `sync` on Windows, where it is intentional).
