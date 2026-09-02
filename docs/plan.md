# Design Plan: agent-sandbox → `agent-dev-env` npm CLI

Status: **complete** — all eight phases shipped: Phase 1 (scaffold, shared
libs, `list`/`status`/`doctor`), Phase 2 (workspace + `bridge-core` +
guest agents + bundling), Phase 3 (macOS platform runner: `runners/`
framework + `tart.ts` + `settings/macos.ts` + macOS guest-agent wiring +
rules), Phase 4 (ssh2 transport + `vmrun.ts` helpers + NAT host-alias
resolution + the ubuntu-vmware runner), Phase 5 (windows-vmware: the
PowerShell transport over ssh2, the shared VMware image flow
(`vmware-image.ts`), auto-logon, HGFS detection, `guest-agent-windows`
wiring with `pipe:` endpoints + schtasks via `install`, hardware upgrade),
Phase 6 (windows-qemu: `qemu.ts` with the swtpm/overlay/hostfwd wiring,
boot + one-time auto-logon, the shared `guest-agent-windows` wiring over
the 10.0.2.2 hostfwd bridge) and Phase 7 (lifecycle —
`build`/`deploy`/`tag`/`watch-build`) — plus Phase 8 (docs + cleanup:
`docs/cli.md`, README rewrite, legacy shell-script removal, watchdog
assets relocation). This document is the design for the whole port; each
phase closed with `pnpm check` (format → lint → typecheck → build → test)
and a per-platform smoke run.

## 1. Overview

Replace the repo's ~20 shell scripts (`scripts/*.sh`, `scripts/lib/*`,
`images/<platform>/{build,deploy}.sh`, `watch-build.*`) with one
TypeScript CLI published on npm as `agent-dev-env` (usable via
`npx agent-dev-env ...`). The npm package bundles everything needed at
runtime: the 4 Packer templates + vars files, `autounattend.xml` /
`autoinstall/` seeds, `qemu-with-tpm.sh`, guest bridge scripts, agent
rules, and the VNC watchdog. The repo remains the source of the CLI +
image recipes; the npm package is the distribution.

Decisions locked in:

- Full rewrite in TypeScript + commander; deps: `commander`, `ssh2`
  (replaces `expect`/`perl`/system `ssh`/`scp`/`iconv`; Node `fetch`
  replaces `curl`).
- Package name `agent-dev-env`; on-disk state uses **new**
  `agent-dev-env` dirs, XDG policy designed from scratch — no migration,
  no legacy paths.
- Default GHCR owner: `ameshkov` (constant, confirmed from git remote).
- Single-version releases: `package.json` version and image
  `image_version`s bump together in one release.
- Host requirement unchanged: macOS (Apple Silicon); Linux = XDG policy
  already in place, no runtime support.

## 2. CLI surface (commander)

```text
agent-dev-env run <platform> [options]     # macos | windows-qemu | windows-vmware | ubuntu-vmware
agent-dev-env stop <platform>
agent-dev-env delete <platform> [--yes] [--pristine]   # --pristine: macOS only
agent-dev-env sync <platform> [--yes]                  # macos | ubuntu-vmware
agent-dev-env status [platform]           # live status of one or all platforms
agent-dev-env list                        # bundled images: name, platform, image_version
agent-dev-env build [image...] [--force] [--no-watchdog]
agent-dev-env deploy [image...] [--owner OWNER]
agent-dev-env tag [image...]              # git-backed; needs a repo checkout
agent-dev-env doctor [--platform P]       # prereq + disk check
agent-dev-env watch-build <vnc-port> [outdir]          # hidden
```

`run` options: `--headless | --foreground`, `--no-agent`, `--no-docker`,
`--no-settings`, `--work-dir PATH`, `--reset`, `--image IMG`,
`--owner OWNER`, `--yes`.

**Env vars** remain as fallback defaults: all existing `SANDBOX_*`
(`SANDBOX_IMAGE`, `SANDBOX_VM`, `SANDBOX_WORK_DIR`, `SANDBOX_MOUNT_NAME`,
`SANDBOX_AGENT_PORT` 4100/4200/4300/4400, `SANDBOX_DOCKER_PORT`
4101/4201/4301/4401, `SANDBOX_OPENCHAMBER_PORT` 4000, `SANDBOX_SSH_PORT`
2222, `SANDBOX_RDP_PORT` 3389, `SANDBOX_WINRM_PORT` 5985,
`SANDBOX_CPU_COUNT`, `SANDBOX_MEMORY_MB`), plus `GHCR_OWNER`,
`WINDOWS_ISO_PATH`, `VIRTIO_WIN_ISO_PATH`, `UBUNTU_ISO_PATH`,
`FUSION_APP_PATH`, `WINDOWS_PASSWORD`, `UBUNTU_PASSWORD`, `NO_COLOR`.
New path overrides: `AGENT_DEV_ENV_DATA_HOME` / `AGENT_DEV_ENV_LOG_DIR` /
`AGENT_DEV_ENV_CACHE_DIR`.

Same VM names, same ports, same guest marker semantics, same
interactive prompts (`y/N` defaults, `--yes` bypass), same `NO_COLOR` +
tty behavior.

## 3. Paths policy (`src/lib/paths.ts` — from scratch, XDG-aware)

Resolution order (highest first):

1. `AGENT_DEV_ENV_DATA_HOME` / `AGENT_DEV_ENV_LOG_DIR` /
   `AGENT_DEV_ENV_CACHE_DIR`.
2. `XDG_DATA_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME` when explicitly
   set (non-empty) — on any OS.
3. Platform defaults:

| Role | macOS | Linux |
| --- | --- | --- |
| Data (images, working VM state) | `~/Library/Application Support/agent-dev-env` | `~/.local/share/agent-dev-env` |
| Logs / runtime state | `~/Library/Logs/agent-dev-env` | `~/.local/state/agent-dev-env` |
| Cache (watchdog frames, build-time downloaded ISOs) | `~/Library/Caches/agent-dev-env` | `~/.cache/agent-dev-env` |

Data layout (`<data>` = resolved data root):

```text
<data>/
  build/<platform>/            # packer build contexts + outputs (build-dir override)
  windows-qemu/<image>/        # image/ (pristine qcow2), working/ (overlay,
                               # efivars.fd, tpm/, pids, socks)
  windows-vmware/<image>/      # image/, base/, working/
  ubuntu-vmware/<image>/       # image/, base/, working/
```

- macOS platform has no data footprint: Tart owns image + working VM
  (`tart pull`/`clone`, `org.cirruslabs.tart`); only
  `~/Library/Logs/agent-dev-env/tart-*.log` is ours. Documented
  asymmetry.
- Guest-side markers become `~/.config/agent-dev-env/…` (settings
  version, agent-rules sha256) since we're green-field.
- No config file in v1 (env + flags only); `XDG_CONFIG_HOME` is a
  documented future hook.
- `build/` lives under data (not cache — `deploy` consumes it); only
  transient watchdog frames and re-downloadable build ISOs go to cache.

## 4. Project layout

pnpm workspace with the CLI as a workspace package: the workspace root
only holds the repo-wide tooling; `packages/agent-dev-env-cli` is the
published npm package; the guest-side packages are workspace-internal
(never published, bundled as single-file JS artifacts into the CLI's dist
at build time and copied into guests by the runners).

```text
package.json                 # private workspace root (dev deps + scripts)
pnpm-workspace.yaml          # packages/*
tsconfig.base.json           # shared TypeScript compiler options
vitest.config.ts             # globals: true
oxlint.config.ts             # correctness category + max-lines/max-lines-per-function
knip.config.ts               # unused-export analysis
.prettierrc / .prettierignore / .markdownlint-cli2.yaml / .husky/pre-commit
packages/
  agent-dev-env-cli/         # the agent-dev-env CLI package (published)
    src/                     # as Phase 1 landed: cli.ts, commands/, runners/,
                             # lifecycle/, lib/ + co-located tests
    scripts/copy-assets.mjs  # build step: tsc + esbuild bundles + copy assets
    tsconfig*.json           # app (build) + test (noEmit) configs
    dist/                    # compiled CLI + bundled runtime artifacts:
                             #   assets/bridge/bridge.js            (host-side forwarder)
                             #   assets/guest/guest-agent-{mac,windows,ubuntu}.js
  bridge-core/               # zero-dep forwarder + endpoint parsing (internal)
    src/                     #   index.ts + endpoints/forwarder/probe + bin.ts
  guest-agent-mac/           # macOS guest agent (internal; bundled)
  guest-agent-windows/       # Windows 11 ARM64 guest agent (internal; bundled —
                             #   shared by qemu + vmware, host alias is a param)
  guest-agent-ubuntu/        # Ubuntu guest agent (internal; bundled)
assets/
  rules/                     # agent-rules.md, agent-rules-linux.md
  watchdog/                  # watch-build.py, watch-build-ocr.swift
  images/                    # copied snapshot of images/* at publish
```

Bundled artifacts are the only distribution of the guest-side code: the
CLI spawns `dist/assets/bridge/bridge.js` for host-side bridges; the
runners SFTP the guest agent bundles into the guests
(`~/.local/lib/agent-dev-env/` / `C:\tools\agent-dev-env\`) and run them
with `node` — no npm install, no registry access inside guests, same
version as the host runner.

## 5. Key shared modules (dedup summary)

| Module | Replaces | Notes |
| --- | --- | --- |
| `logger` | 9 copy-pasted color blocks | `c_*`/`ce_*`, `die/warn/title/step/info/cmd/ok`, tty+`NO_COLOR` |
| `prompt` | 7x `confirm()` | `y/N`, non-tty newline behavior |
| `vars` | 6x `read_var` sed | quoted-string + number parse; regex port |
| `template` | all sed placeholder substitutions | unified `{{TOKEN}}`; assets migrate from `__X__` |
| `exec` | repeated spawn/nohup/alarm | `run()`, `spawnDetached` (log+pid), `withTimeout`, `killTree` |
| `ghcr` | 6x owner discovery | `GHCR_OWNER` → `--owner` → git remote regex → `ameshkov` |
| `bridge-core` | host-side socat x2 + `brew install socat` prompts | zero-dep forwarder (endpoints, listen/forward); bundled to `dist/assets/bridge/bridge.js` for host-side spawns (pidfile, no lsof matching) |
| `guest-agent-*` | bridge-relay.js, bridges.ps1, start-relays.cmd, guest-setup.sh systemd units, macOS zprofile socat blocks, mac/ubuntu rules heredocs | per-platform guest packages: `install`/`bridge`/`status`/`rules`/`uninstall`; bundled single-file, SFTP'd into guests (no npm in guest) |
| `tart` | tart invocations | list/ip/clone/set/run/stop/exec(-i)/pull wrappers |
| `vmrun` | `lib/vmware.sh` + `windows-vmware/lib.sh` | bin resolution (`FUSION_APP_PATH`), `-T fusion`, hwVersion/toolsState/guestIp/upgradevm with `withTimeout` (60/30/180 s), setDisplayName awk port |
| `qemu` | runtime swtpm/qemu/overlay | args builder (exact `launch_qemu` port), hostfwd, `backing-image.txt` marker, efivars seed |
| `ssh` | expect+perl+system ssh/scp | ssh2: password auth, `exec` (+pty for sudo), SFTP uploads, `waitForSshd` (auth-error probe semantics), `utf16le` base64 for `-EncodedCommand` |
| `ifconfig`/dhcpd | NAT-segment resolution | vmnet8 subnet + host-alias extraction (both VMware runners, Ubuntu seed) |
| `settings/` | `macos-settings.sh`, `ubuntu-vmware/settings.sh` | one file set; two transports (tart tar stdin / ssh2+sftp staging) |
| `catalog` | `list_images()/find_vars_file()` x3 + wrapper resolution | bundled images: name ↔ platform ↔ vars ↔ defaults |

The QEMU runner's inline heredoc twin (`render_guest_setup`,
run-windows-qemu:677-775) disappears entirely: the Windows and Ubuntu
guest bridges become instances of the CLI's own `bridge` subcommand (see
section 6 for the full design). `bridge-relay.js`, `bridges.ps1`,
`start-relays.cmd` and the Ubuntu `guest-setup.sh` systemd units are
deleted; only thin registration templates (schtasks, systemd units) stay
in `assets/guest/`. The ASCII-only rule for the remaining PowerShell
snippets stays enforced by a unit test; the qemu bash-3.2 heredoc
workaround note becomes obsolete.

## 6. Guest agents + bridge design

**Problem**: guest-side bridges today are per-platform helper scripts —
`scripts/lib/windows-vmware/bridge-relay.js` (Node named-pipe relay),
`bridges.ps1` + `start-relays.cmd` (relay launchers + `SSH_AUTH_SOCK` /
docker context setup), `scripts/lib/ubuntu-vmware/guest-setup.sh`
(systemd units running `socat`), and the macOS runner's `socat` heredocs
in `~/.zprofile`. The host side is `socat` on every platform too, with a
`brew install socat` prompt each time. Each copy is a separate
implementation of the same idea — a port forwarder between a local
stream endpoint and the host — impossible to unit test and easy to drift.

**Solution**: a pnpm workspace. The shared forwarder lives in a
zero-dependency `packages/bridge-core`; each platform gets its own
**guest agent** package — `packages/guest-agent-mac`,
`packages/guest-agent-windows` (shared by the QEMU + VMware Windows
backends — only the host alias differs, it's a parameter), and
`packages/guest-agent-ubuntu`. The agents are workspace-internal
(never published), bundled as single-file JS by `scripts/copy-assets.mjs`
(esbuild) into the CLI's dist, and copied into the guests by the runners
— no npm install inside guests, no registry access, same version as the
host runner.

**Guest agent surface** (tiny CLI, no external deps; invoked in the guest
with `node guest-agent-<platform>.js <command>`):

```text
guest-agent-<platform> install [--agent-port N] [--docker-port N] [--host-alias X]
guest-agent-<platform> bridge ssh-agent|docker     # runs the forwarder
guest-agent-<platform> status                      # bridge-up/docker-up lines
guest-agent-<platform> rules [--probe|--force]     # mac/ubuntu only; content on stdin
guest-agent-<platform> uninstall
```

- `install` is idempotent and writes the platform's persistence +
  settings: macOS launchd user agent + `~/.zprofile`/`~/.ssh/config`
  exports (replaces the socat heredocs), Ubuntu systemd user units +
  `/etc/profile.d/` exports (replaces `guest-setup.sh`), Windows
  schtasks ONLOGON + user `SSH_AUTH_SOCK` env + docker context `host`
  (replaces `bridges.ps1`/`start-relays.cmd`/`guest-setup.ps1`).
- `rules` moves the mac/ubuntu agent-rules probe/install (content
  rendered host-side, streamed on stdin; sha256 marker semantics
  unchanged) out of the runner heredocs into the agent.
- What stays host-side: ssh2 transport, settings tar-copy, rules content
  rendering, `doctor`/`list`/`status`, lifecycle — plus the host-side
  bridge spawns, which run the same forwarder:
  `dist/assets/bridge/bridge.js` (bundled from `bridge-core`, spawned
  detached with a pidfile), so host and guest sides share one
  implementation.

**Endpoint syntax** (bridge-core):

| Endpoint | Meaning | Used for |
| --- | --- | --- |
| `unix:/path` | Unix socket | macOS/Ubuntu guest agent + docker sockets; host agent/docker sockets |
| `pipe:name` | Windows named pipe (`\\.\pipe\name`) | Windows guest `openssh-ssh-agent` + `docker_engine` |
| `tcp:host:port` | TCP connect | guest → host (NAT alias, Tart gateway, 10.0.2.2) |
| `tcp:host:port` (listen) | TCP listen; host+port is the bind address | host side (bound to the NAT/gateway address) |

**Wiring** (per bridge, guest side → host side):

| Role | Guest side | Host side |
| --- | --- | --- |
| ssh-agent | `--listen unix:/tmp/ssh-agent.sock` (or `pipe:openssh-ssh-agent`) → `--forward tcp:<host-alias>:<agent-port>` | `bridge.js --listen tcp:<gw>:<agent-port>` → `--forward unix:<SSH_AUTH_SOCK>` |
| docker | `--listen unix:/tmp/docker.sock` (or `pipe:docker_engine`) → `--forward tcp:<host-alias>:<docker-port>` | `bridge.js --listen tcp:<gw>:<docker-port>` → `--forward unix:<engine-sock>` |

Benefits: maintainability (one forwarder in `bridge-core`, per-platform
agents with their own registration logic), testability (endpoint parsing
unit tests, real loopback socket tests in `bridge-core`, registration
template tests per agent), fewer host prerequisites (no socat — `doctor`
drops the socat check), and one version everywhere (bundled artifacts
ship inside the CLI package).

### Helper scripts inventory (what each becomes)

| Helper | Role today | New home |
| --- | --- | --- |
| `scripts/lib/windows-vmware/bridge-relay.js` | Windows guest named-pipe→TCP relay | deleted — `guest-agent-windows bridge` |
| `scripts/lib/windows-vmware/bridges.ps1` | relay launcher + SSH_AUTH_SOCK + docker context | deleted — `guest-agent-windows install` |
| `scripts/lib/windows-vmware/start-relays.cmd` | detached relay starter | deleted — schtasks registered by `install` |
| `scripts/lib/windows-vmware/guest-setup.ps1` | autologon + schtasks + relay install | shrinks to autologon + `install` invocation (runner step) |
| `scripts/lib/windows-vmware/lib.sh` | vmrun/winrm helpers | `vmrun.ts` / `ssh.ts` (as planned) |
| `scripts/lib/ubuntu-vmware/guest-setup.sh` | systemd units running socat + profile.d + OpenChamber restart | deleted — `guest-agent-ubuntu install`; OpenChamber restart stays a runner step |
| `scripts/lib/ubuntu-vmware/settings.sh` | host settings copy | `settings/ubuntu.ts` (as planned) |
| `scripts/lib/macos-settings.sh` | host settings copy + helpers | `settings/macos.ts` + `logger`/`prompt` (as planned) |
| `scripts/lib/vmware.sh` | vmrun resolution + hw upgrade | `vmrun.ts` (as planned) |
| `scripts/watch-build.{sh,py}` + `watch-build-ocr.swift` | VNC build watchdog | `watch-build` command + bundled watchdog assets (as planned) |
| `images/windows-arm64-qemu/qemu-with-tpm.sh` | build-time swtpm bootstrap | stays a packaged asset (host-side, build-only) |
| `scripts/agent-rules{,-linux}.md` | guest agent rules content | `assets/rules/` (as planned) |

## 7. Runner framework (`runners/framework.ts` + 4 backends)

Shared step order, per-platform hooks (port of the shell flow,
section-for-section):

1. **Preflight** — arch/OS check, state dirs, VM prereqs,
   stale-bridge detection, `--reset` teardown.
2. **Image select** — `--image`/`SANDBOX_IMAGE` → catalog default →
   local build output → GHCR pull (macOS: `tart pull`; others: `oras
   pull` into `<data>/<platform>/<image>/`), incl.
   `backing-image.txt`/`base-archive.txt` identity markers.
3. **Working VM** — macOS: `tart clone` + `tart set` (cpu/mem/disk) +
   `--dir` = `SANDBOX_WORK_DIR`/`--work-dir` (Tart mounts under
   `/Volumes/My Shared Files/<name>`); QEMU: COW overlay + efivars;
   VMware pair: extract → `base/` → `vmrun clone` → `working/` →
   `.hw-version` marker → `upgradevm` (180 s cap) →
   `set_vm_display_name`; Ubuntu additionally registers HGFS once tools
   state is `running` (warning for Windows ARM: not supported).
4. **Boot** — macOS: `tart run` (headless `--no-graphics` /
   foreground attach, `--no-audio`), wait IP+running; QEMU: qemu args +
   hostfwd on 127.0.0.1, `wait_for_sshd` (150x4 s incl. qemu-alive
   check); VMware: `vmrun start gui|nogui` + `getGuestIPAddress` retry +
   tools-state gate.
5. **Guest prep** — QEMU: `ensure_autologon` (registry check → confirm
   → set + reboot + wait_for_sshd).
6. **Bridges** — host: agent socket discovery (`SSH_AUTH_SOCK` override
   semantics), Docker socket discovery (Desktop/Colima/OrbStack/
   `/var/run`), then one `spawnDetached` bridge per bind (`tart` gateway
   `.1`, `127.0.0.1`, NAT alias) with pidfiles under `<state>/working/` —
   no socat, no `brew install socat` prompt — and verify guest `docker
   info` (ServerVersion; else warn "start the host engine").
   Guest: SFTP the platform's bundled guest agent into the guest,
   run `guest-agent install` (launchd / systemd / schtasks), then probe
   with `guest-agent status` (the old `bridge-up` / `bridge-status:`
   semantics, now machine-readable) and verify guest `docker info`.
7. **Agent rules** — macOS/Ubuntu only: render
   `{{HOST_WORK_DIR}}`/`{{GUEST_MOUNT}}`/`{{NAT_GATEWAY}}` host-side,
   drop SSH section when no bridge, then stream into the guest agent's
   `rules --probe` / `rules --force` (sha256 marker semantics
   unchanged).
8. **Settings** — macOS/Ubuntu only (`--no-settings`); version markers
   (macOS 9 / Ubuntu 3 kept as-is so fresh-guests semantics match).
9. **Verify OpenChamber** — fetch `/`
   (`http://<tart-ip|127.0.0.1|guest-ip>:4000`, 60x2 s); macOS:
   open-in-browser confirm.
10. **Summary** — VM/IP, shared dir, SSH agent + Docker state lines
    (unchanged wording).
11. **Cleanup** — trap on SIGINT/SIGTERM in foreground mode: kill the
    host bridges + qemu, remove pid files; VM stays running (macOS stop
    semantics unchanged).

## 8. Lifecycle commands

### build

- `catalog` from bundled `dist/assets/images/*/vars/*.pkrvars.hcl`;
  output root `<data>/build/<platform>/` (seed the "do not pre-create
  output dir" rule), context materialized into
  `<data>/build-context/<platform>/` with `qemu-with-tpm.sh` chmod'd on
  demand.
- macOS: `packer init` + `packer build -var-file` (tart plugin).
- windows-qemu: arch/packer/qemu/qemu-img/swtpm/hdiutil/xmllint checks;
  `WINDOWS_ISO_PATH` + sha256 (from `iso_sha256`); virtio-win
  download/cache + sha256; `hdiutil` driver staging
  (viostor/vioscsi/NetKVM/viogpudo, ARM64 tree check); build swtpm
  (fresh tpmstate); watchdog (opt-in per deps); `PKR_VAR_*` +
  `SWTPM_SOCK`/`VIRTIO_WIN_ISO_PATH`/`QEMU_WITH_TPM_LOG` env;
  `xmllint --noout`; `packer init`/`fmt -check`/`build -var
  build_dir=…`; zstd compress + `qemu-img info`.
- windows-vmware: Fusion path (vars `vmware_fusion_app_path` →
  `FUSION_APP_PATH` → default), `drivers-arm64.zip` + `windows.iso`
  presence, `unzip -jo` vmxnet3 trio staging, watchdog, packer
  pipeline, post-build `upgradevm` (180 s).
- ubuntu-vmware: `UBUNTU_ISO_PATH` + sha256; seed server (python
  http.server port 8004 + lsof taken-check + pgid kill); vmnet8 subnet
  from Fusion dhcpd.conf; `WATCH_BUILD_BOOT_CMD` (escaped `\;`
  autoinstall line with `s=http://<nat-host>:8004/`); watchdog types
  grub; packer; `upgradevm`.
- `--force` → `-force`; `--no-watchdog` skips; watchdog port pinned
  5901.

### deploy

- Owner: `GHCR_OWNER` → `--owner` → git remote regex (inside a
  checkout) → `ameshkov`.
- macOS: `tart push <image> --chunk-size 3` → `:image_version` +
  `:latest`.
- QEMU: `oras push --artifact-type application/vnd.agent-sandbox.qcow2`
  from output dir (bare filename), tag ref `:version,latest`.
- VMware: tar.gz of `*.vmx *.nvram *.vmdk` (excl `*.log`), `oras push
  --artifact-type application/vnd.agent-sandbox.vmware-vm`.

### tag

Git-backed (annotated, clean-tree, `[tag]` CHANGELOG entry,
no-overwrite) — requires `--repo` or a checkout of this repo; clear
error otherwise. Repo-side conventions: see AGENTS.md → Project
Conventions.

### watch-build / doctor

- `watch-build`: port of `watch-build.sh` — vncdotool+swiftc checks,
  swiftc compile-if-stale, `exec` spawn of bundled `watch-build.py`.
- `doctor`: per-platform prereq table with install hints + free-disk
  estimate (against `disk_size` vars + ~50 GB base image) — supersedes
  the scattered `require_cmd` blocks. Phase 1 ships `doctor` (host,
  arch, disk, and per-platform tooling checks).

## 9. Release flow (single version)

- One release = one npm publish of the CLI: bump the workspace version
  **and** image `image_version`s together; tag
  `agent-dev-env-v<version>` (git tag rule stays in `tag.ts`, now also
  allowing the root tag) — repo CHANGELOG.md records the release;
  per-image `images/<platform>/CHANGELOG.md` keeps recipe history
  (validated by `tag` when tagging image releases).
- The guest-agent packages and `bridge-core` are workspace-internal;
  they are never published — their bundled single-file artifacts ship
  inside the CLI package's dist and carry the same version.
- Still two GHCR tag sets: `<image>:<image_version>` + `:latest` via
  `deploy`.
- `deploy`/`tag` need npm-published snapshot + repo checkout
  respectively — documented.

## 10. Implementation phases

1. **Scaffold** — DONE. pnpm + tsconfig split + vitest +
   `copy-assets.mjs`, `paths.ts` (XDG policy), `logger`/`prompt`/
   `vars`/`template`/`ghcr`/`exec`/`git`/`platform`/`vmrun`/`catalog` +
   co-located unit tests, `doctor`, `list`, `status`; toolchain
   mirrors ameshkov/mcp-compress-router (oxlint, Prettier,
   Markdownlint, Knip, husky, `pnpm check`, exact version pins).
2. **Workspace + guest agents** — `pnpm-workspace.yaml` +
   `packages/{bridge-core,guest-agent-mac,guest-agent-windows,
   guest-agent-ubuntu}`; endpoints + forwarder (loopback integration
   tests), per-agent `install`/`status`/`rules` (registration template
   unit tests), esbuild bundling in `copy-assets.mjs`;
   host-side `spawnDetached` of `dist/assets/bridge/bridge.js` +
   pidfile consumption; `doctor` drops the socat check.
3. **macOS platform** (tart only) — runner framework, `tart.ts`,
   `settings/macos.ts`, macOS guest-agent wiring + `rules`; MAC
   run/stop/delete/sync green.
4. **ssh2 transport + ubuntu-vmware** — `ssh.ts`, `vmrun.ts`, Ubuntu
   guest-agent wiring + HGFS + rules.
5. **windows-vmware** — PS transport, `guest-agent-windows` wiring
   (`pipe:` endpoints + schtasks via `install`), hardware upgrade.
6. **windows-qemu** — `qemu.ts` (swtpm/overlay/hostfwd), autologon,
   same `guest-agent-windows` wiring (bridge-relay.js, bridges.ps1 and
   start-relays.cmd deleted).
7. **Lifecycle** — `build` (all four flows), `deploy`, `tag`,
   `watch-build`, CHANGELOG/release docs.
8. **Docs + cleanup** — `docs/cli.md` (absorb the four "Runner script
   reference" sections), rewrite README (npx quickstart), migrate
   `docs/*.md`/`DEVELOPMENT.md`/`AGENTS.md`, delete `scripts/*.sh`,
   `scripts/lib/**`, `images/*/{build,deploy}.sh`, and move
   `watch-build.*`, agent rules and guest templates into `assets/`,
   markdownlint pass.

Each phase closes with: `pnpm typecheck`, unit tests,
`npm pack --dry-run` (run from `packages/agent-dev-env-cli`), and a real
per-platform smoke run (the only end-to-end check available; no CI
exists).

## 11. Risks & mitigations

- **Behavior parity** — section-for-section porting (all current
  scripts read), identical prompts/ports/env names, smoke tests per
  platform.
- **ssh2 edge cases** — transport isolated in `ssh.ts`; fallback: spawn
  system ssh with an expect-like TS wrapper without touching callers.
- **Detached processes** — `spawnDetached`+pidfiles+logs kept; `stop`
  kills by pidfile/listener exactly as today (incl. `pkill --worker`
  belt-and-braces for the watchdog in VMware builds).
- **Windows PS assets** — ASCII-only enforced by a test (AGENTS.md
  gotcha preserved).
- **Windows named pipes** — `guest-agent-windows` uses the same Node
  `net` code path as the Unix/TCP endpoints, covered by loopback
  integration tests; the `pipe:` endpoints are verified in the
  per-platform smoke runs.
- **npx cold start** — commander+ssh2 only, dist precompiled.

## 12. Out of scope / notes

- Windows guests get no `sync` (no settings step today) — `sync` errors
  helpfully for `windows-*`.
- `delete --pristine` stays macOS-only.
- `.gitignore`: remove `build/`-repo paths, add `dist/` (done), keep
  `*.tvm`, `__pycache__` cleanup.
- No CI added; image-recipe docs ("What's in the image" tables etc.)
  stay in sync with templates (unchanged practice).
