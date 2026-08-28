# AGENTS.md

Sandbox VM image recipes for AI coding agents: Packer templates (Tart) that
build a macOS VM with a full coding toolchain, plus user docs. There is no app
code, no tests, no CI — the deliverable is the Packer config, the vars files,
and the docs. Read [DEVELOPMENT.md](DEVELOPMENT.md) before touching image
recipes; it is the authoritative build/release guide.

## Layout

- `images/mac/sandbox.pkr.hcl` — the only Packer template; source is the
  `tart-cli` builder (Cirrus Labs base images from GHCR, `tart-cli` clones a
  `ghcr.io/cirruslabs/macos-<version>-xcode:<tag>` base).
- `images/mac/vars/<image>.pkrvars.hcl` — one vars file per image (per macOS
  version): OS/toolchain versions, VM resources, `image_version`. Single
  source of truth for versions — wire changes through template variables,
  never hardcode in the template.
- `images/windows-arm64-qemu/` — Windows 11 (ARM64) sandbox images: Packer QEMU
  template (`sandbox.pkr.hcl`) with `autounattend.xml` + `build.sh` /
  `qemu-with-tpm.sh` wrappers (the platform build wrapper is required — swtpm,
  the bring-your-own ISO, and the ARM64 virtio driver staging can't be
  expressed in the template).
- `images/windows-arm64-vmware/` — the VMware sibling: Packer `vmware-iso`
  template (`sandbox.pkr.hcl`) with `autounattend.xml` + `build.sh` /
  `deploy.sh` wrappers (the ARM64 vmxnet3 driver staging + the VMware Tools
  attach come from the Fusion app bundle; the published artifact is a tar.gz
  of the output vmx/vmdk). Same guest and toolchain as the QEMU image.
- `images/ubuntu-arm64-vmware/` — Ubuntu 24.04 LTS (ARM64) sandbox image:
  Packer `vmware-iso` template with an `autoinstall/` cloud-init seed
  (user-data + meta-data; served by a wrapper-started HTTP server on port
  8004, fetched via the kernel's `ds=nocloud-net`; the grub autoinstall
  command is typed by the VNC build watchdog via `WATCH_BUILD_BOOT_CMD`
  because the plugin's own boot typing raced the firmware's probe cycle)
  and `build.sh` / `deploy.sh` wrappers. No Fusion driver/tools staging
  (vmxnet3 + NVMe are in-box in the Ubuntu kernel; open-vm-tools come
  from the Ubuntu archive — Fusion ships no Linux tools ISO for arm64
  guests). Same bare-metal mechanics as the Windows VMware image: NAT +
  vmxnet3 + EFI, tar.gz OCI artifact.
- `scripts/build.sh`, `scripts/deploy.sh`, `scripts/tag.sh` — wrappers that
  discover images from `images/*/vars/*.pkrvars.hcl`; they resolve the repo
  root themselves, so run them from anywhere. `build.sh` delegates to a
  platform's `build.sh` when the platform directory ships one.
- `scripts/run-macos-sandbox.sh` — user-facing runner: pulls/clones the sandbox
  if needed, runs it with the recommended settings, bridges the host's SSH
  agent into the guest (see `docs/ssh-agent.md`) and the host's Docker engine
  into the guest when one is running (see `docs/macos.md`), copies the host's
  user settings into the guest once per VM (versioned marker inside the guest,
  see `docs/macos.md`), installs the sandbox environment rules into the
  guest's agents (`scripts/agent-rules.md`), and verifies OpenChamber.
- `scripts/run-windows-qemu-sandbox.sh` — user-facing runner for the Windows
  sandbox: boots the qcow2 under QEMU + swtpm (working VM = COW overlay +
  persistent TPM/NVRAM under `~/Library/Application Support/agent-sandbox/`),
  forwards SSH/RDP/WinRM/OpenChamber ports, bridges the host's SSH agent and
  Docker engine into the guest (Node relays on named pipes + host socat),
  and verifies OpenChamber. See `docs/windows-qemu.md`.
- `scripts/run-windows-vmware-sandbox.sh` — user-facing runner for the
  VMware Windows sandbox: extracts the vmx/vmdk archive and clones a
  working VM with `vmrun` (Fusion NAT; no port forwarding — the guest IP
  comes from `vmrun getGuestIPAddress`), bridges the host's SSH agent and
  Docker engine into the guest the same way, optionally shares a host
  folder (HGFS, `--work-dir`), and verifies OpenChamber. See
  `docs/windows-vmware.md`.
- `scripts/run-ubuntu-vmware-sandbox.sh` — user-facing runner for the
  Ubuntu VMware sandbox: same vmrun cloning/IP/NAT mechanics as the
  Windows runner, with Linux guests — bridges the host's SSH agent and
  Docker engine as systemd **user** services (`socat` relays rendered from
  `scripts/lib/ubuntu-vmware/`, linger enabled in the image), shares a host
  folder (HGFS, `--work-dir` → `/mnt/hgfs/work`), installs the sandbox
  agent rules (`scripts/agent-rules-linux.md`) into the guest's
  opencode/Copilot configs, copies the host's user settings into the guest
  once per VM (versioned marker, `--no-settings` skips; same file set as
  the macOS runner), and verifies OpenChamber. See `docs/ubuntu-vmware.md`.
- `scripts/stop-macos-sandbox.sh`, `scripts/stop-windows-qemu-sandbox.sh`,
  `scripts/stop-windows-vmware-sandbox.sh`,
  `scripts/stop-ubuntu-vmware-sandbox.sh` — user-facing counterparts to the
  `run-*` scripts: stop the sandbox VM (`tart stop` / `vmrun stop`, the QEMU
  one kills qemu + swtpm via the runner's pid files) and kill the host socat
  bridge listeners the runner left up.
- `scripts/delete-macos-sandbox.sh`,
  `scripts/delete-windows-qemu-sandbox.sh`,
  `scripts/delete-windows-vmware-sandbox.sh`,
  `scripts/delete-ubuntu-vmware-sandbox.sh` — delete the sandbox: stop it
  (delegating to the matching `stop-*` script), then remove the VM/state —
  `tart delete` for the macOS VMs (optionally the pristine image with
  `--pristine`), `rm -rf` of the state dir for the Windows/Ubuntu ones
  (working VM disk/clone + TPM/NVRAM/overlay + pulled image cache). Asks
  first unless `--yes`.
- `scripts/agent-rules.md` — sandbox environment rules installed into the
  guest's coding agents (opencode global `AGENTS.md`, Copilot CLI
  `copilot-instructions.md`): Docker remote-engine topology, shared-directory
  path mapping, SSH agent bridge. The runner templates in the actual
  work-dir/mount paths, drops the SSH section when no agent bridge is up,
  asks before installing or updating the rules, and only replaces
  user-modified files after a confirmation. `scripts/agent-rules-linux.md`
  is the Ubuntu-guest flavor (installed by `run-ubuntu-vmware-sandbox.sh`).
- `scripts/sync-macos-sandbox.sh` — user-facing: copies the host's user
  settings (opencode config/agents/skills/commands/plugins, Copilot
  config/skills, SSH/Git dotfiles)
  into the guest on demand and restarts OpenChamber; requires a running VM.
- `scripts/sync-ubuntu-vmware-sandbox.sh` — the Ubuntu-guest counterpart of
  the sync script above: same file set (guest paths mapped to the Linux
  layout), same marker, same OpenChamber restart; requires a running
  sandbox VM.
- `scripts/lib/macos-settings.sh` — shared code for the two scripts above:
  output helpers, VM helpers, and the user-settings copy logic
  (`collect_settings_files`, marker, OpenChamber restart). Keep the settings
  logic here, not in the scripts.
- `scripts/lib/vmware.sh` — shared vmrun helpers for the VMware sandboxes
  (vmrun resolution, post-build hardware-version upgrade, vmx displayName);
  sourced by the VMware platform `build.sh` files and both VMware runners.
- `scripts/lib/windows-vmware/` — shared helpers for the VMware Windows
  sandbox: `lib.sh` (shim forwarding to `../vmware.sh`) and the
  guest-side bridge templates (`bridge-relay.js`, `bridges.ps1`,
  `start-relays.cmd`, `guest-setup.ps1`) that the runner renders into the
  guest.
- `scripts/lib/ubuntu-vmware/` — the Ubuntu VMware sandbox's shared
  templates/libs: the guest bridge template (`guest-setup.sh`: systemd user
  services + profile.d exports, rendered with the run's host alias and
  bridge ports by the runner) and the host-side user-settings copy logic
  (`settings.sh`: SSH/scp transport, guest-layout mapping, gitconfig
  sanitization for `/home/admin`, marker; shared by the runner and the
  sync script).
- `docs/` — user guides. `macos.md`, `windows-qemu.md`, `windows-vmware.md`,
  `ubuntu-vmware.md` and `ssh-agent.md` are real.
- `images/mac/CHANGELOG.md` — per-image changelog, keep in sync with
  `image_version`; always keeps an `[Unreleased]` section on top and links to
  the release tags (`mac-v<version>`) at the bottom.

## Commands

- Build one image: `./scripts/build.sh sandbox-macos-tahoe` (all images if no
  arg). Fails if a VM with that name already exists — `tart delete
  sandbox-macos-tahoe` first. The Windows images are built with
  `WINDOWS_ISO_PATH=/path/to/iso ./scripts/build.sh sandbox-windows-11-arm64-qemu`
  (QEMU) or `./scripts/build.sh sandbox-windows-11-arm64-vmware` (VMware),
  and the Ubuntu image with
  `UBUNTU_ISO_PATH=/path/to/iso ./scripts/build.sh sandbox-ubuntu-24-04-arm64-vmware` —
  `build.sh` delegates to the platform wrapper (`images/windows-arm64-qemu/build.sh`
  for swtpm + ISO staging, `images/windows-arm64-vmware/build.sh` for the
  Fusion ARM64 driver staging, `images/ubuntu-arm64-vmware/build.sh` for
  the ISO check + autoinstall build; the Windows builds run a VNC build
  watchdog, `scripts/watch-build.sh`, that auto-dismisses Windows Setup
  dialogs — needs `pip3 install vncdotool`), see the platform READMEs.
- Fast HCL check without a build (from `images/mac/`):
  `packer validate -var-file=vars/<image>.pkrvars.hcl sandbox.pkr.hcl`.
- Publish: `./scripts/deploy.sh <image>` — pushes `<version>` + `:latest` to
  `ghcr.io/<owner>/<image>`; macOS needs a one-time `tart login ghcr.io` with
  `packages:write`, the Windows images delegate to their platform deploy
  wrappers (`images/windows-arm64-qemu/deploy.sh`,
  `images/windows-arm64-vmware/deploy.sh`, oras push — needs
  `brew install oras` + `oras login ghcr.io`). Owner comes from the git
  remote, override with `GHCR_OWNER`.
- Tag a release: `./scripts/tag.sh <image>` — creates and pushes the annotated
  git tag `<platform>-v<version>` (e.g. `mac-v1.2.0`); fails on a dirty tree
  or a missing `[<tag>]` CHANGELOG entry. Run after committing a release,
  before `build.sh` + `deploy.sh`.
- Verify Markdown: `npx --yes markdownlint-cli2@0.23.2 .` — lints every
  `*.md` file in the repo against `.markdownlint-cli2.yaml` (repo root); pass
  `--fix` to auto-fix what can be fixed automatically.

## Releases & tags

- Version source of truth: `image_version` in the image's vars file; every
  release bumps it. Git tags are repo-wide, so a release tag is prefixed with
  the platform: `<platform>-v<version>` (e.g. `mac-v1.2.0`). This is separate
  from the GHCR push tags, which are `<image>:<image_version>` + `:latest`.
- Every version bump creates a tag: bump `image_version`, add the CHANGELOG
  entry, commit, then `./scripts/tag.sh <image>`. `tag.sh` enforces the rules:
  it refuses to tag a dirty working tree (so the tag always points at the
  release commit, never at uncommitted changes), refuses a changelog without a
  `[<tag>]` entry, and never overwrites an existing tag. The tag is annotated
  and pushed to origin.
- CHANGELOG format (`images/mac/CHANGELOG.md`, mirrored for new platforms):
    - Always keep `## [Unreleased]` on top — never remove it. *All* new
      changes land there, under a `###` section (Added/Changed/Fixed/...);
      never create or edit a release heading while landing changes.
    - A release heading is the tag name: `## [mac-v1.2.0] - <date>` (Keep a
      Changelog / semver). It is created only in the release step, when
      `image_version` is bumped and the tag is cut — not per change.
    - At the bottom: `[unreleased]` → compare URL against the newest tag, and
      one `[mac-vX.Y.Z]` → `releases/tag/mac-vX.Y.Z` per release. Update both
      in the same change as the release entry, never for Unreleased changes.
- Release sequence: bump + changelog entry → commit → `./scripts/tag.sh
  <image>` → `./scripts/build.sh <image>` → `./scripts/deploy.sh <image>`.
  The full guide is in DEVELOPMENT.md → "Releasing a new image version".

## Conventions & gotchas

- Image name = vars file name = VM name = `sandbox-macos-<macos-version>`
  (macOS) or `sandbox-windows-<windows_version>-arm64-qemu` /
  `sandbox-windows-<windows_version>-arm64-vmware` (Windows) or
  `sandbox-ubuntu-<ubuntu_version>-arm64-vmware` (Ubuntu). The Xcode
  version is **not** part of the mac name (it only selects the base
  image). Never introduce a separate naming scheme.
- Every release: bump `image_version` in the vars file, add a CHANGELOG entry,
  commit, create the release tag, then `build.sh` + `deploy.sh` — see
  "Releases & tags" above. Keep them in sync.
- Any change to an image — the Packer template, its vars file, or the
  provisioner scripts — must be recorded in `images/mac/CHANGELOG.md`, not
  just released versions. Update the changelog in the same change as the
  image itself; never land an image change without a corresponding entry.
- Build prerequisites: Apple Silicon host (Tart VMs can't run on Intel),
  Tart + Packer via Homebrew, ~150 GB free disk; the first build pulls the
  ~50 GB base image. `PACKER_LOG=1` for verbose output.
- SSH provisioning credentials are fixed by the Cirrus base images:
  `admin`/`admin`.
- `scripts/deploy.sh` pushes images flat as `ghcr.io/<owner>/<image>` — the
  platform is part of the image name (`sandbox-macos-…`,
  `sandbox-windows-…-arm64-qemu`, `sandbox-windows-…-arm64-vmware`),
  so no path mapping is needed; mirror the `mac` layout (template + `vars/` +
  README + CHANGELOG) when a new platform lands.
- Docs are part of the deliverable and must stay in sync with the template:
  the "What's in the image" table in `docs/macos.md`, the layout tree in
  `DEVELOPMENT.md`, and `images/mac/README.md` all describe the image — change
  them together.
- There is no automated verification: the only end-to-end check is a full
  image build (~1 hr). Use `packer validate` and review the provisioner shell
  scripts (`set -e -x` inline blocks) carefully before running a build.
- Every Markdown file must pass markdownlint before landing — run
  `npx --yes markdownlint-cli2@0.23.2 .` from the repo root and fix all
  findings, see the "Markdown Formatting" section below. The config is
  `.markdownlint-cli2.yaml` at the repo root.

## Markdown Formatting

All Markdown files MUST follow these formatting rules:

- **Line length**: Keep lines at most 80 characters. This is not a hard
  lint gate, but SHOULD be followed for readability. Lines inside fenced
  code blocks are exempt from this limit.
- **Unordered lists**: Use dashes (`-`) for bullet points. Indent nested
  list items by 4 spaces.
- **Emphasis**: Use asterisks (`*`) for emphasis (`*italic*`,
  `**bold**`). Do NOT use underscores.
- **Headings**: Duplicate heading names are allowed only among sibling
  headings (same parent level). Avoid duplicates across different levels.
- **Inline HTML**: Avoid raw HTML in Markdown. The only allowed elements
  are `<a>`, `<p>`, `<details>`, `<summary>`, and `<img>`.
- **Trailing spaces**: Do NOT leave trailing whitespace on any line. Do
  NOT use two-space line breaks — use a blank line instead.
- **Bare URLs**: Bare URLs are permitted and do not need to be wrapped
  in angle brackets.
- **Table formatting**: Align table columns with padding when the table
  fits within 80 characters. If the table exceeds 80 characters or
  triggers an MD060 linter warning, switch to a compact format using
  single spaces only. This applies to the separator row as well — it
  should be written as `| --- |`, not `|--|`.

  Example of correct layout:

  ```markdown
  | Col1 | Col2 |
  | --- | --- |
  | Value1 | Value2 |
  ```

  Do NOT use extra padding or alignment characters beyond single spaces.

**Rationale**: Uniform Markdown formatting improves readability for both
humans and AI agents that consume project documentation.
