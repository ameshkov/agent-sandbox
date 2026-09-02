# Changelog

All notable changes to the Ubuntu sandbox images (VMware).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The image version lives in the image's vars file (`image_version`); every
release bumps it, adds an entry below, and tags the release commit
`<platform>-v<version>` (e.g. `ubuntu-arm64-vmware-v1.0.0`). The
`[Unreleased]` section on top is never removed — changes land there until
the next release.

## [Unreleased]

### Added

- **Host user settings sync into the Ubuntu guest** — the runner now copies
  the host's user settings into the guest like the macOS sandbox does
  (opencode config + auth, OpenCodeReview config, Copilot config + skills,
  VS Code extensions + user config, mcp-compress-router settings, SSH
  dotfiles, `.gitconfig`), once per VM, tracked by a versioned marker
  (`~/.config/agent-dev-env/settings-copied`), with `--no-settings` to skip
  and `agent-dev-env sync` (ubuntu-vmware) to re-sync on demand. The
  shared logic is `settings/ubuntu.ts` + `settings/ubuntu-copy.ts` (ssh2
  transport, host-to-guest path mapping for the VS Code user dir and
  mcp-compress-router, `.gitconfig` rewritten for `/home/admin`,
  OpenChamber restart). See `docs/ubuntu-vmware.md`.

### Fixed

- **The shared host directory no longer fails when the share is
  registered before VMware Tools are up** — `agent-dev-env run`
  (ubuntu-vmware) called `vmrun addSharedFolder` as soon as sshd answered,
  but open-vm-tools can still be starting then: `getGuestIPAddress`/sshd
  were already up while the tools state vmrun needs for the HGFS
  registration was not, so the runner logged `Error: The VMware Tools are
  not running in the virtual machine` and `/mnt/hgfs/work` never appeared
  in the guest. The runner now waits for `vmrun checkToolsState` to report
  `running` (up to 5 min) and retries `addSharedFolder` a few times, then
  warns only if it still failed. A share persisted by a previous run
  (`Error: Already exists`) is treated as success.
- **Host user settings copy no longer fails on the root-owned `~/.local`** —
  the sync unpack hit `tar: Cannot utime` / `Permission denied` and aborted:
  the image's `install -d -o admin -g admin
  /home/admin/.local/share ...` left the *intermediate* `.local` directory
  root-owned (install only applies `-o/-g` to its operands), so the sandbox
  user could not write into `~/.local` or restore its timestamps during
  `tar -C $HOME` extraction. `install -d` now lists `/home/admin/.local`
  as its own operand, and the runner's settings copy
  (`settings/ubuntu-copy.ts`) chowns `~/.local` back to the
  sandbox user before unpacking (via `sudo -S` with the guest password the
  runner already knows), so existing images are fixed on the next run
  without a rebuild. The copy also strips macOS AppleDouble companions
  (`._*`) and `.DS_Store` from the staged archive and cleans up any `._*`
  junk a previous partial copy left in the guest — the AppleDouble files
  were packed as ordinary files, and one of them (`._share`) is what first
  made the extraction hit the root-owned directory.
- **mcp-compress-router settings land where the router looks for them** —
  the settings copy mapped the host's
  `~/Library/Application Support/mcp-compress-router/` to
  `~/.config/mcp-compress-router/`, but mcp-compress-router's
  `defaultConfigDir` on Linux is the XDG **data** dir,
  `~/.local/share/mcp-compress-router/` (a different path from macOS and
  Windows), so the synced `mcp.json`/credentials were never picked up.
  The mapping now targets `~/.local/share/mcp-compress-router/` (where
  `mcp.json`/`.jsonc`, `credentials.json`, `tools-cache.json` and `.env`
  all live), the settings version was bumped so already-provisioned
  guests re-copy, and the unpack drops the stale `~/.config` copy.
- **The build watchdog no longer misses the grub menu** — the Ubuntu build
  can fail with "Timeout waiting for SSH" when the grub autoinstall
  command is never typed: grub's menu countdown is ~20 s wide, but
  `assets/watchdog/watch-build.py` polled once per ~2 min (90 s worker
  timeout + 20 s sleep), so the menu default booted the interactive
  Subiquity installer and the build sat on the installer's proxy screen
  until SSH timed out. The supervisor now fast-polls (3 s interval — the
  worker timeout stays at 90 s, since a kill mid-typing would corrupt the
  grub shell input line) while the autoinstall command is untyped (no
  `.boot-typed` marker), falling back to the old slow cadence once typed
  or after a 4 min cap; the relaying is unchanged. The build flow's
  watchdog stop also kills the supervisor's in-flight `--worker`
  children (they survive a supervisor kill and keep the VNC port open,
  blocking the next build).

## [ubuntu-arm64-vmware-v1.1.0] - 2026-08-25

### Added

- **GNOME desktop in the image** — `ubuntu-desktop-minimal` (GNOME Shell +
  GDM3 + core apps) and `open-vm-tools-desktop` (SVGA Xorg driver,
  clipboard, drag-and-drop) are installed by the Packer provisioners, the
  VM boots to `graphical.target`, and GDM3 auto-logs in `admin` — the
  Fusion window opens straight on the desktop (VS Code, Firefox,
  OpenChamber-in-browser). The session runs on Xorg (`WaylandEnable=false`):
  Fusion guests get no GPU acceleration, and the Xorg session works best
  with the open-vm-tools input drivers. Display is
  software-rendered (llvmpipe) — for human interaction, not 3D.

### Changed

- The grub kernel command is typed by the **build watchdog**
  (`scripts/watch-build.py` gained a `WATCH_BUILD_BOOT_CMD` mode: grub
  menu/shell detected in the OCR → type the autoinstall command, once per
  build, marker-guarded) instead of the Packer `boot_command` — the
  firmware's No-Media/PXE probe cycle before grub appears is
  variable-length (~20-40 s on Fusion), so packer-side typing fired
  before grub was up and the menu's default entry booted the interactive
  Subiquity installer. A `boot-typed.png` frame is captured after typing
  for debugging.
- The autoinstall seed is served by a small HTTP server the build wrapper
  starts on a fixed port (`python3 -m http.server 8004` over
  `autoinstall/`; the seed is fetched via
  `ds=nocloud-net;s=http://<vmnet8-host>:8004/`) instead of
  `http_directory` — the plugin's HTTP server uses a random port and does
  not accept an `http_port` override, and the URL must be known when the
  grub command is typed. The vmnet8 host address is read from Fusion's
  DHCP config.
- `identity.password` in the seed uses a clean crypt salt (the previous
  salt contained '!', not a valid crypt salt character).

### Fixed

- The provisioner heredocs used `$$` for shell variables (HCL only
  escapes `$${`; bash expanded `$$` to its PID — observed as `$NVM_DIR`
  set to "4330HOME/.nvm"). They now use plain `$`.
- `set_vm_display_name` in `scripts/lib/vmware.sh` matched only the
  camelCase `displayName` key, but `vmrun clone` writes lowercase
  `displayname` — the rename then *appended* a second, case-variant key,
  and Fusion refuses a vmx with duplicate keys ("Cannot read the virtual
  machine configuration file"), so the runner's first `vmrun start` failed
  on freshly cloned VMs. It now matches case-insensitively and writes the
  canonical lowercase key, dropping duplicates.
- The guest-side bridge setup used plain `sudo`, but the runner's SSH
  sessions are deliberately pty-less (raw-stdin uploads depend on it), so
  sudo failed with "a terminal is required". `sudo` now runs with `-S`
  (password from stdin, answered by the runner's expect session, whose
  prompt pattern matches "[sudo] password for ..." too), and
  `guest-setup.sh` writes the profile.d file to a temp path and installs
  it with `sudo -S install` — `sudo -S tee <<EOF` would eat the first
  heredoc line as the password.
- The base apt list uses the 24.04 `t64` names (`libasound2t64`,
  `libfuse2t64`, `libgtk-3-0t64`) — the plain names have no install
  candidates.
- Docker plugin installs use the `docker-` prefixed names
  (`docker-compose`, `docker-buildx` — docker only discovers prefixed
  plugin files) and mirror them into the user plugin dirs; the buildx
  URL includes the release's `v` prefix (the tag and asset are
  `v0.36.1`/`buildx-v0.36.1.linux-arm64`).
- opencode is installed via the official installer script
  (`curl https://opencode.ai/install | bash`) — the npm package
  postinstall mis-selects the arm64-musl binary on glibc systems
  (EBADPLATFORM) — and the XDG dirs (`~/.local/share` and friends) are
  pre-created with correct ownership (opencode's first run hit EACCES).
- Google Chrome is not part of the image: CfT publishes no linux-arm64
  build (only x86_64 linux64) and Ubuntu's chromium is snap-only; Firefox
  (official linux-aarch64 releases) is the browser.
- The final verification checks nvm/node/npm, opencode/ocr/openchamber
  and rust through the sandbox user (they live in the user's home, and
  the verification shell runs as root).
- Removed the invalid `user-data:`/`late-commands` blocks from the seed:
  subiquity's schema rejected them ("Cloud config schema errors ...
  Additional properties are not allowed"), aborting autoinstall —
  despite the seed being served fine. The seed exactly matches the first
  proven build.

## [ubuntu-arm64-vmware-v1.0.0] - 2026-08-25

### Added

- **New platform: Ubuntu 24.04 LTS (ARM64) sandbox image for VMware
  Fusion** — `images/ubuntu-arm64-vmware/`:
    - `sandbox.pkr.hcl` — Packer `vmware-iso` template (same Proven
    ARM64 wiring as the Windows VMware image: `guest_os_type
    "arm-ubuntu-64"`, hardware version 20, NVMe disk, vmxnet3 NIC under
    NAT, EFI firmware, headless + VNC on the pinned port 5901). Ubuntu
    Server 24.04 ARM64 is autoinstalled via Subiquity: the installer
    kernel gets `autoinstall ds=nocloud-net;s=http://.../` in the
    `boot_command` and fetches `autoinstall/user-data` +
    `meta-data` from Packer's HTTP server (LVM layout, user
    `admin`/sandbox1, openssh-server, open-vm-tools). Provisioned over
    SSH; the image ships the same toolchain as the other sandboxes
    (apt base toolchain, hash-pinned Go/Rust/nvm Node/GitHub CLI/VS
    Code/Chrome CfT/Firefox/Docker CLI + compose + buildx, npm globals
    opencode/`ocr`/OpenChamber). OpenChamber runs as a systemd **user**
    service (`agent-sandbox-openchamber`, linger enabled) on
    `0.0.0.0:4000`.
    - `vars/sandbox-ubuntu-24-04-arm64-vmware.pkrvars.hcl` — Ubuntu point
    release, ISO SHA256, all pinned toolchain versions + hashes, VM
    resources, credentials, OpenChamber, `image_version`.
    - `build.sh` — platform wrapper: ISO SHA256 verification, `packer
    init` + `packer build` into `build/ubuntu-arm64-vmware/`, VNC build
    watchdog, post-build `vmrun upgradevm` hardware upgrade (shared
    helper, see below). No driver/tools staging from Fusion is needed —
    the vmxnet3 + NVMe drivers are in-box in the Ubuntu kernel
    (verified: `vmxnet3.ko` ships in the base `linux-modules` package)
    and open-vm-tools come from the Ubuntu archive (Fusion ships no
    Linux tools ISO for arm64 guests).
    - `deploy.sh` — platform wrapper: packs the output directory into a
    tar.gz and pushes `ghcr.io/<owner>/<image>:<version>,latest` as an
    OCI artifact via `oras`.
    - `README.md` — build/publish flow, "What's in the image", gotchas.
- **`scripts/lib/vmware.sh`** — the generic vmrun helpers (vmrun
  resolution, hardware-version upgrade, vmx displayName) factored out of
  `scripts/lib/windows-vmware/lib.sh` (which is now a thin shim sourcing
  it), shared by both VMware platforms.
- **`scripts/run-ubuntu-vmware-sandbox.sh`** — user-facing runner: picks
  the archive (env override → local build output → GHCR pull via oras),
  extracts the pristine VM + `vmrun clone`s a working VM (one-time
  hardware-version upgrade), boots it (headless or windowed), discovers
  the guest IP via open-vm-tools, and bridges the host's SSH agent and
  Docker engine into the guest — host-side `socat` on TCP 4400/4401
  bound to the vmnet8 address + guest-side systemd user services
  (`scripts/lib/ubuntu-vmware/guest-setup.sh` renders socat relays for
  `/tmp/ssh-agent.sock` and `/tmp/docker.sock` plus the
  `/etc/profile.d` exports, auto-start via linger). Optionally shares a
  host directory (`--work-dir`, HGFS → `/mnt/hgfs/work`), installs the
  sandbox agent rules (`scripts/agent-rules-linux.md`) into the guest's
  opencode + Copilot configs, and verifies OpenChamber.
- **`scripts/stop-ubuntu-vmware-sandbox.sh` / `delete-ubuntu-vmware-sandbox.sh`** —
  stop the working VM (`vmrun -T fusion stop`, graceful + hard fallback)
  and kill the host bridge listeners; delete the state dir (extracted
  base + working clone + pulled image cache) after a confirmation.
- **`scripts/agent-rules-linux.md`** — sandbox environment rules for the
  Ubuntu guest (shared-directory path mapping, host Docker engine via
  `/tmp/docker.sock`, published ports at the NAT gateway, SSH agent
  socket).
- **Docs**: `docs/linux.md` replaces its "not supported yet" placeholder
  with the full Ubuntu VMware sandbox guide; `README.md`,
  `DEVELOPMENT.md` and `AGENTS.md` list the new platform and the
  shared `scripts/lib/vmware.sh` helper.

[unreleased]: https://github.com/ameshkov/agent-sandbox/compare/ubuntu-arm64-vmware-v1.1.0...HEAD
[ubuntu-arm64-vmware-v1.1.0]: https://github.com/ameshkov/agent-sandbox/releases/tag/ubuntu-arm64-vmware-v1.1.0
[ubuntu-arm64-vmware-v1.0.0]: https://github.com/ameshkov/agent-sandbox/releases/tag/ubuntu-arm64-vmware-v1.0.0
