# Development Guide

This document is for people who contribute image recipes to this repository.

## What is a "recipe"?

Each supported platform has a directory under `images/` containing:

1. **A Packer template** (`*.pkr.hcl`) — describes how to build the image:
   the base image it derives from, the resources of the VM, and the
   provisioning steps that install software.
2. **Shared build scripts** ([`scripts/build.sh`](scripts/build.sh),
   [`scripts/deploy.sh`](scripts/deploy.sh)) — thin wrappers that run
   `packer init` + `packer build` and `tart push` for a chosen image (or for
   all images when called without an argument).
3. **Variables files** (`vars/*.pkrvars.hcl`) — one file per image (macOS
   version): the OS version, disk size and the image's semantic version.

The running side of a recipe (how to run the VM, share directories, the SSH
agent bridge, etc.) lives in the per-OS user guides under [docs/](docs/) —
keep them in sync whenever you change how an image behaves.

## Repository layout

```text
├── README.md                      # Index: point of entry to all docs
├── DEVELOPMENT.md                # This document
├── scripts/                       # Shared build, deploy & tag scripts (repo root)
│   ├── agent-rules.md             # sandbox environment rules for the guest's agents (installed by the runner)
│   ├── build.sh                   # ./scripts/build.sh [<image>]  — packer init + build
│   ├── deploy.sh                  # ./scripts/deploy.sh [<image>] — push to GHCR
│   ├── tag.sh                     # ./scripts/tag.sh [<image>]    — create & push the release git tag
│   ├── lib/macos-settings.sh      # shared: output helpers + user-settings copy logic (runner + sync)
│   ├── lib/windows-vmware/        # shared: vmrun + hw-version upgrade helpers (lib.sh), guest bridge templates
│   ├── run-macos-sandbox.sh       # user-facing: pull/run a VM + SSH agent & Docker bridges + user settings + OpenChamber
│   ├── run-windows-sandbox.sh     # user-facing: boot the Windows qcow2 (QEMU) + SSH agent & Docker bridges + OpenChamber
│   ├── run-windows-vmware-sandbox.sh # user-facing: run the Windows VMware sandbox (vmrun) + bridges + OpenChamber
│   └── sync-macos-sandbox.sh      # user-facing: copy host user settings into the guest on demand
├── docs/                          # User-facing, per host OS setup guides
│   ├── macos.md                   # macOS (Apple Silicon) — pull & run, details
│   ├── linux.md                   # placeholder (not supported yet)
│   ├── windows-qemu.md            # Windows 11 (ARM64) guest under QEMU — run, details
│   ├── windows-vmware.md          # Windows 11 (ARM64) guest under VMware Fusion — run, details
│   └── ssh-agent.md               # share the host's SSH agent with the guest
├── build/                         # Per-image build artifacts (gitignored)
└── images/
    ├── mac/                       # macOS guest images (host: Apple Silicon Mac)
    │   ├── sandbox.pkr.hcl        # Packer template for all macOS images
    │   ├── README.md              # Image list, build/publish commands
    │   ├── CHANGELOG.md           # Per-version changelog of the images
    │   └── vars/                  # One .pkrvars.hcl per image (macOS version)
    │       └── sandbox-macos-tahoe.pkrvars.hcl
    ├── windows-arm64-qemu/        # Windows 11 (ARM64) guest images (host: Apple Silicon)
    │   ├── sandbox.pkr.hcl        # Packer template (QEMU plugin)
    │   ├── autounattend.xml       # Windows unattended install config
    │   ├── build.sh               # Platform build wrapper (ISO staging + swtpm + packer)
    │   ├── deploy.sh              # Platform deploy wrapper (oras push of the qcow2)
    │   ├── qemu-with-tpm.sh       # qemu_binary wrapper (TPM/USB/CD wiring)
    │   ├── README.md
    │   ├── CHANGELOG.md
    │   └── vars/
    │       └── sandbox-windows-11.pkrvars.hcl
    └── windows-arm64-vmware/      # Windows 11 (ARM64) guest images, VMware (host: Apple Silicon)
        ├── sandbox.pkr.hcl        # Packer template (vmware-iso plugin)
        ├── autounattend.xml       # Windows unattended install config
        ├── build.sh               # Platform build wrapper (Fusion driver staging + packer)
        ├── deploy.sh              # Platform deploy wrapper (tar.gz + oras push)
        ├── README.md
        ├── CHANGELOG.md
        └── vars/
            └── sandbox-windows-11-vmware.pkrvars.hcl
```

## macOS images

### How they are built

`images/mac/sandbox.pkr.hcl` uses the
[Tart Packer plugin](https://github.com/cirruslabs/packer-plugin-tart) (source
`tart-cli`). The builder:

1. **Clones a Cirrus Labs base image** from GHCR
   (`ghcr.io/cirruslabs/macos-<version>-xcode:<xcode-tag>`) — a pre-built
   macOS with Xcode, Homebrew, SSH (`admin`/`admin`) and the Tart Guest Agent.
   Available tags:
   https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos-
2. **Boots it headless** and provisions it over SSH (`admin`/`admin`):
   - system setup: Xcode license, Remote Login, Screen Sharing, **auto-login**
     as `admin` (boots to the desktop; also creates the unlocked
     `login.keychain` required for headless runs on macOS 15+);
   - Homebrew toolchain: `nvm` (Node.js version manager; installs the
     `node_version` from the vars file as the default), `python@<python_version>`
     (also from the vars file), `ruby` + CLI
     utilities (`brew_formulas` variable — includes `socat` for SSH agent
     sharing, see [docs/ssh-agent.md](docs/ssh-agent.md), and the Docker CLI
     with `docker compose`/`docker buildx` plugins — client only, the guest
     can't run a local container engine, see
     [docs/macos.md](docs/macos.md)); unversioned
     `python`/`pip` aliases;
   - Visual Studio Code (latest stable, from
     `update.code.visualstudio.com`) with the `code` CLI on PATH;
   - Sublime Text (latest stable, Homebrew cask `sublime-text`) with the
     `subl` CLI on PATH;
   - Google Chrome and Mozilla Firefox (latest stable universal macOS
     builds, via Homebrew casks; quarantine is stripped with `xattr` so they
     launch without Gatekeeper prompts);
   - OpenCode (`brew install anomalyco/tap/opencode`);
   - OpenCodeReview (`npm install -g @alibaba-group/open-code-review`) — the
     `ocr` AI code review CLI; its global config
     (`~/.opencodereview/config.json`) is synced from the host with the user
     settings (see "User settings on the guest" in docs/macos.md);
   - OpenChamber desktop app (`brew install --cask openchamber`) — the
     native macOS app for the guest desktop; quarantine stripped so it
     launches without Gatekeeper prompts;
   - OpenChamber (`npm install -g @openchamber/web`) — web UI for OpenCode;
     installed as a login service (LaunchAgent) listening on `0.0.0.0:4000`,
     reachable from the host at `http://<vm-ip>:4000` (see
     [docs/macos.md](docs/macos.md)). The build pins the absolute `opencode`
     path into the service via `OPENCODE_BINARY` (the `startup enable`
     environment snapshot);
   - final version check.
3. Leaves a runnable VM named `sandbox-macos-<macos-version>`.

### Prerequisites (local builds)

- macOS host with **Apple Silicon** (Tart VMs cannot run on Intel).
- [Tart](https://tart.run/): `brew install cirruslabs/cli/tart`
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`
  (the Tart plugin is installed automatically by `packer init`).
- ~150 GB free disk space.

### Building an image

```bash
# Run from the repository root
./scripts/build.sh sandbox-macos-tahoe
```

Without an argument, `./scripts/build.sh` builds every image in
`images/*/vars/`. Run it with an image name to build just that one.

Notes:

- The first build pulls the ~50 GB base image — be patient.
- The builder **fails if a VM with the same name already exists** (Packer
  leaves the VM in `~/.tart/vms/`). Delete it first:
  `tart delete sandbox-macos-tahoe`.
- Set `PACKER_LOG=1` for verbose Packer output.

### Adding a new macOS version

An image is a single macOS version; the image name is fixed per version
(`sandbox-macos-<macos-version>`) and does not include the Xcode version.
To add a new one:

1. Pick a base image tag from the
   [Cirrus Labs package list](https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos-)
   (e.g. `macos-sequoia-xcode:15.4`).
2. Copy the latest vars file:

   ```bash
   cp images/mac/vars/sandbox-macos-tahoe.pkrvars.hcl \
      images/mac/vars/sandbox-macos-sequoia.pkrvars.hcl
   ```

3. Edit the new vars file: set `macos_version` / `xcode_version` /
   `node_version` / `python_version` / `disk_size`, set `image_version` to
   `1.0.0`, and add image-specific brew formulas to `extra_brew_formulas` if
   needed.
4. Build locally (`./scripts/build.sh sandbox-macos-sequoia`) and make sure it
   works.
5. Add a `CHANGELOG.md` entry for the initial version.
6. Commit the new image.

Image naming convention: `sandbox-macos-<macos-version>` (e.g.
`sandbox-macos-tahoe`). The vars file name **must** match the image name — it
is used as the VM name and as the GHCR image name. Git release tags are
`<platform>-v<version>` (e.g. `mac-v1.2.0`), see "Releasing a new image
version" below.

### Template variables

| Variable | Type | Default | Description |
| --- | --- | --- | --- |
| `macos_version` | string | — | Cirrus base image macOS version, e.g. `tahoe`; part of the image name (`sandbox-macos-<macos_version>`) |
| `xcode_version` | string | — | Cirrus base image Xcode tag, e.g. `26.4.1` (selects the base image only; not part of the image name) |
| `node_version` | string | — | Node.js version installed via nvm and set as the default, e.g. `26` |
| `python_version` | string | — | Homebrew Python version, e.g. `3.14` (also used for the unversioned `python`/`pip` aliases) |
| `image_version` | string | — | Semantic version this image is published under; bump it + add a `CHANGELOG.md` entry per release |
| `disk_size` | number | `160` | VM disk size in GB; must be ≥ the Cirrus base image disk (140 GB), tart can only grow a disk |
| `cpu_count` | number | `4` | CPU count of the VM |
| `memory_gb` | number | `8` | RAM of the VM in GB |
| `ssh_username` | string | `admin` | SSH user used for provisioning (fixed in the Cirrus Labs base images) |
| `ssh_password` | string | `admin` | SSH password used for provisioning (fixed in the Cirrus Labs base images) |
| `openchamber_ui_password` | string | `sandbox` | Password protecting the OpenChamber web UI; required because the server binds to `0.0.0.0` (host access: `http://<vm-ip>:4000`, see [docs/macos.md](docs/macos.md)) |
| `brew_formulas` | list(string) | core toolchain | Installed by `brew install` in every image |
| `extra_brew_formulas` | list(string) | `[]` | Image-specific additions to `brew_formulas` |

### Publishing

Images are published to GHCR with a semantic version tag (from
`image_version` in the image's vars file) plus `:latest`:

```bash
# One-time: authenticate with a token that has `packages:write`
# (create one: https://github.com/settings/tokens/new?scopes=write:packages&description=agent-sandbox)
tart login ghcr.io

# Push the locally built VM with its version tag and :latest
./scripts/deploy.sh sandbox-macos-tahoe
```

`./scripts/deploy.sh` without an argument pushes every image. The GHCR owner
is taken from the git remote (`git@github.com:<owner>/agent-sandbox.git`) and
can be overridden with the `GHCR_OWNER` env var.

The first push of an image creates a new GHCR package, and GitHub does
**not** link it to this repository automatically. After the first
`deploy.sh` run, open the package settings page
(`https://github.com/users/<owner>/packages/container/<image>/settings`)
and link it to `agent-sandbox`; until then it does not show up on the
repository's Packages tab. New packages are also **private** by default —
change the visibility to public on the same page if the images should be
pullable by anyone.

### Releasing a new image version

1. Make the image changes in `images/mac/sandbox.pkr.hcl` (and/or
   `vars/sandbox-macos-tahoe.pkrvars.hcl`).
2. Bump `image_version` in the image's vars file.
3. Add a `CHANGELOG.md` entry describing the changes. The entry's heading is
   the release tag (`[mac-v1.2.0] - <date>`), and the changelog must always
   keep an `[Unreleased]` section on top for changes that are not released
   yet; update the tag links at the bottom (the `[unreleased]` compare link
   moves to the new tag) in the same change.
4. Commit the release — the working tree must be clean before tagging.
5. Create and push the release tag:

   ```bash
   ./scripts/tag.sh <image-name>
   ```

   `tag.sh` reads `image_version` from the vars file, verifies the working
   tree is clean and that the `[<tag>]` entry exists in the changelog, and
   creates an annotated `<platform>-v<version>` tag on the release commit
   (e.g. `mac-v1.2.0`), then pushes it to origin. The changelog's tag links
   resolve to it.
6. Build the image locally (`./scripts/build.sh <image-name>`) and push the
   new version tag plus `:latest` to GHCR with
   `./scripts/deploy.sh <image-name>` (see "Publishing" above).

## Windows images

### How they are built

`images/windows-arm64-qemu/sandbox.pkr.hcl` uses the
[QEMU Packer plugin](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu)
(source `qemu`). Windows 11 ARM64 is installed from the official Microsoft
ISO (bring-your-own — Microsoft does not permit redistribution, so the ISO
is not in the repo) with `autounattend.xml` answering Setup. The builder:

1. **Boots an ARM64 VM under QEMU on Apple Silicon's HVF accelerator**
   (near-native speed; HVF can only virtualize ARM64 guests, so the image
   is ARM64-only). `machine_type = "virt,gic-version=max"`, `cpu_model =
   "host"`, UEFI via the edk2 AAVMF firmware that Homebrew's qemu ships,
   and a TPM 2.0 provided by `swtpm` (a Windows 11 system requirement).
   The install ISO, the unattend CD, and virtio-win.iso are all attached
   as usb-storage devices (the ARM `virt` machine has no IDE/SATA
   controller and WinPE has in-box xHCI drivers); the TPM, display, USB
   input and CD wiring is appended by `qemu-with-tpm.sh`, which wraps
   `qemu-system-aarch64` because the plugin's `qemuargs` option replaces
   its auto-generated args instead of appending.
2. **Installs Windows unattended.** `autounattend.xml` (all components
   `processorArchitecture="arm64"`): pure-UEFI disk layout (ESP + MSR +
   NTFS), "Windows 11 Pro" image, LabConfig bypasses for the Win11
   hardware checks (required because `-cpu host` advertises Apple Silicon
   to the guest), OOBE bypass for the Microsoft-account requirement, and
   FirstLogonCommands that register the staged virtio drivers (NetKVM
   does not survive the WinPE → installed-system handoff), force the
   network profile to Private, and bring up WinRM on 5985.
3. **Provisions over WinRM** (`Administrator`/password from the vars
   file, elevated token): virtio guest tools (full driver suite + qemu
   guest agent), Chocolatey + toolchain (Node.js, Python, Git, GitHub
   CLI, ripgrep, jq, curl, Chrome, Firefox, Docker CLI — versions pinned
   in the vars file), Visual Studio Code (native arm64, direct download),
    OpenCode (`opencode-ai`), OpenCodeReview (`ocr`), the OpenChamber web
    UI as a native service on port 4000 (with the `OPENCODE_BINARY` pin,
    like the macOS template), OpenSSH Server + RDP, and the bridge
    tooling (`socat` + `npiperelay` ship as utilities; the sandbox runner
    uses in-image Node relays instead — see docs/windows-qemu.md). Finishes
    with hardening (Defender realtime scan, telemetry/indexer services,
    hibernation), a version banner, and cleanup.
4. Leaves a qcow2 disk image at
   `build/windows-arm64-qemu/output/sandbox-windows-11.qcow2`,
   compressed with zstd. Per-image build artifacts (output/,
   packer_cache/, drivers/staging/) live in a top-level
   `build/windows-arm64-<platform>/` directory; the tart
   (macOS) images build no files and have no such directory.

### Prerequisites (local builds)

- macOS host with **Apple Silicon** (HVF, see above).
- [QEMU](https://www.qemu.org/): `brew install qemu`
- [swtpm](https://github.com/stefanberger/swtpm): `brew install swtpm`
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`
  (the QEMU plugin is installed automatically by `packer init`).
- The Windows 11 ARM64 ISO (see `images/windows-arm64-qemu/README.md` for the
  download steps) — `WINDOWS_ISO_PATH` must be set when building.

### Building an image

```bash
# From the repository root; the ISO is required
WINDOWS_ISO_PATH=/path/to/Win11_24H2_English_Arm64.iso \
  ./scripts/build.sh sandbox-windows-11
```

`scripts/build.sh` delegates to `images/windows-arm64-qemu/build.sh` (a
platform
wrapper — see its header comment), which verifies the ISO against
`iso_sha256` from the vars file, downloads virtio-win.iso into
`build/windows-arm64-qemu/packer_cache/` when
`VIRTIO_WIN_ISO_PATH` is unset, stages the ARM64 driver subset into
`build/windows-arm64-qemu/drivers/staging/` (packed into the
unattend CD — WinPE drive letters on ARM64 are non-deterministic, so a
separate drivers CD is unreliable), starts `swtpm`, and runs
`packer init` + `packer build`. A build takes roughly 30 minutes on an
M-series Mac.

### VMware images (`images/windows-arm64-vmware`)

The VMware sibling reuses the same Windows 11 Pro ARM64 guest and
provisioners (the Choco/toolchain, OpenChamber, OpenSSH, and hardening
provisioners are identical to the QEMU template) but is built with the
[vmware-iso builder](https://github.com/vmware/packer-plugin-vmware)
(`github.com/vmware/vmware` plugin v2+, Fusion 13.6+ on Apple Silicon):

1. **Fusion hosts the installer** — `guest_os_type "arm-windows11-64"`,
   hardware version 20, NVMe disk (in-box driver — no WinPE storage driver
   needed), vmxnet3 NIC on NAT, EFI firmware. The plugin drives Fusion via
   `vmrun`; the build is headless (VNC on the pinned port 5901) and, like
   the QEMU image, runs the shared build watchdog.
2. **The unattend CD carries the only staged driver** — the ARM64 vmxnet3
   NIC driver (inf/sys/cat), extracted by `build.sh` from the Fusion app
   bundle (`Contents/Library/isoimages/arm64/drivers-arm64.zip`) into
   `drivers/staging/`. Windows 11 ARM64 has no in-box VMware NIC driver,
   so `FirstLogonCommands` order 1 installs it before any network use
   (WinRM from the host would never come up otherwise); WinPE is offline,
   so no WinPE driver is staged.
3. **VMware Tools are attached, not downloaded** — the builder's
   `tools_mode "attach"` plugs in Fusion's own ARM64 tools ISO
   (`Contents/Library/isoimages/arm64/windows.iso`), so the tools version
   always matches the host Fusion; `autounattend.xml` installs them at
   first logon, *before* WinRM comes up — the tools installer rebinds the
   NIC and kills a live WinRM session, so a provisioner-based install
   times out. The tools are what make `vmrun getGuestIPAddress` and
   HGFS shared folders work at runtime).
4. **Leaves a runnable vmx + vmdk** at
   `build/windows-arm64-vmware/output/sandbox-windows-11-vmware.vmx`
   (disk type 0, monolithic sparse; no build-time snapshot — the runner
   makes a full `vmrun clone` as the working VM). `build.sh` then upgrades
   the VM to the hardware version the installed Fusion writes for a new VM
   (`vmrun upgradevm`, shared helper `scripts/lib/windows-vmware/lib.sh`):
   the builder's level 20 VM would show a one-time "Upgrade this virtual
   machine?" prompt on the first GUI start under a newer Fusion (22 on
   Fusion 26). The runner upgrades its working clone the same way, so
   artifacts built by older Fusion versions start clean too.

Prerequisites: macOS + Apple Silicon, VMware Fusion 13.6+ (free for
personal use), Packer, and the same bring-your-own Windows 11 ARM64 ISO
(`WINDOWS_ISO_PATH`). Build:

```bash
WINDOWS_ISO_PATH=/path/to/Win11_25H2_English_Arm64_v2.iso \
  ./scripts/build.sh sandbox-windows-11-vmware
```

The runtime side is `scripts/run-windows-vmware-sandbox.sh` — no port
forwarding: the guest sits on Fusion's NAT network (vmnet8) and the host
is its router, so the runner just discovers the guest IP via VMware Tools
and exposes the bridges on the host's NAT address (the guest's default
gateway — Fusion's NAT runs in userspace, no host interface; see
[docs/windows-vmware.md](docs/windows-vmware.md)).

### Build watchdog

The headless build is not self-driving: its `boot_command` types Enter 15
times at boot to answer the firmware's prompts, and those stray keys can
hit "Cancel" on Windows Setup's "Installing Windows 11" screen — Setup
then asks "Are you sure you want to quit?" and the build stalls forever.
Boot races can also land in the UEFI shell. The template pins the plugin's
VNC server to port 5901 and `build.sh` starts
[`scripts/watch-build.sh`](scripts/watch-build.sh) around `packer build`:
it polls the VNC framebuffer, OCRs each frame with Apple Vision
(`scripts/watch-build-ocr.swift`, compiled on first use), and

- clicks "No" on the quit-confirmation dialog (at the OCR'd button
  position, with a fallback for the 800x600 framebuffer),
- presses a key when "Press any key to boot from CD or DVD" is on screen,
- boots the ISO from the UEFI shell (`fs0:` + `EFI\BOOT\BOOTAA64.EFI`).

The Python supervisor ([`scripts/watch-build.py`](scripts/watch-build.py))
runs every capture in a subprocess with a hard timeout, so a hung
VNC/OCR cycle cannot stall the watch. Prerequisites: `pip3 install
vncdotool` + the Xcode command line tools; `build.sh` skips the watchdog
with a warning when they are missing. Frames and logs land in
`build/windows-arm64-<platform>/packer_cache/watchdog/`
(gitignored).

### Template variables

| Variable | Type | Default | Description |
| --- | --- | --- | --- |
| `windows_version` | string | — | Windows guest version, e.g. `11`; part of the image name (`sandbox-windows-<windows_version>`) |
| `image_version` | string | — | Semantic version this image is published under; bump it + add a `CHANGELOG.md` entry per release |
| `iso_path` | string | — | Absolute path to the Windows 11 ARM64 ISO (set by the build wrapper, not in the vars file) |
| `iso_sha256` | string | `` | SHA256 of the Windows ISO (verified by the build wrapper; empty = skip) |
| `virtio_win_iso_path` | string | — | Path to virtio-win.iso (set by the build wrapper) |
| `virtio_win_url` | string | stable URL | Download URL used by the build wrapper when `VIRTIO_WIN_ISO_PATH` is unset |
| `virtio_win_sha256` | string | `` | SHA256 of virtio-win.iso (verified by the build wrapper; empty = skip) |
| `nodejs_version` / `python_version` / `github_cli_version` / `ripgrep_version` / `git_version` / `jq_version` | string | pinned | Choco package versions installed in every image |
| `open_code_review_version` | string | pinned | `ocr` version installed via npm |
| `disk_size` | number | `100` | VM disk size in GB |
| `cpu_count` | number | `4` | CPU count of the VM |
| `memory_gb` | number | `8` | RAM of the VM in GB |
| `winrm_username` | string | `Administrator` | WinRM provisioning user; must match `autounattend.xml` |
| `winrm_password` | string | `sandbox1` | WinRM provisioning password; must match `autounattend.xml` |
| `openchamber_ui_password` | string | `sandbox` | Password protecting the OpenChamber web UI |
| `openchamber_port` | number | `4000` | TCP port of the OpenChamber web UI in the guest |
| `qemu_binary` | string | `./qemu-with-tpm.sh` | qemu binary (or wrapper) Packer invokes |
| `efi_firmware_code` / `efi_firmware_vars` | string | Homebrew edk2 AAVMF | UEFI firmware paths (read-only code + NVRAM template) |
| `vnc_bind_address` / `vnc_port_min` / `vnc_port_max` | string/number | `127.0.0.1` / `5901` / `5901` | VNC server for the build watchdog (pinned so `build.sh` can start it without scanning for the port) |

### Publishing

The macOS images are pushed with `tart push`; the Windows images are plain
files (qcow2 / vmx+vmdk tar.gz), so the platform deploy wrappers
(`images/windows-arm64-qemu/deploy.sh`,
`images/windows-arm64-vmware/deploy.sh`) push them to GHCR as OCI
artifacts with `oras` — `scripts/deploy.sh` delegates to them
automatically (mirroring the `build.sh` delegation):

```bash
# From the repository root; needs `brew install oras` and a GHCR token
# with write:packages (`oras login ghcr.io`)
./scripts/deploy.sh sandbox-windows-11
./scripts/deploy.sh sandbox-windows-11-vmware
```

This pushes `ghcr.io/<owner>/<image>:<image_version>` and `:latest` for
each. Consumers pull the file back by its name, e.g.
`scripts/run-windows-sandbox.sh` runs `oras pull` into its state dir when
no local build output exists (the VMware runner does the same for the
tar.gz).

## Adding a new platform

To add a new host/guest combination (e.g. macOS host → Linux guest), create a
new `images/<platform>/` directory following the macOS pattern:

1. Packer template with the appropriate builder (e.g. QEMU, or the
   [qocker](https://github.com/AdGuardSoftwareLimited/qocker) Vmfile approach
   for layered Linux images). If the platform needs host-side preparation
   that plain `packer build` cannot do (like the Windows ISO staging and
   swtpm), add a platform `build.sh` wrapper — `scripts/build.sh` delegates
   to it automatically. If it needs a different push mechanism (like the
   Windows qcow2 vs Tart VMs), add a platform `deploy.sh` wrapper —
   `scripts/deploy.sh` delegates the same way.
2. `vars/` image files + a `CHANGELOG.md` (the shared `scripts/build.sh` and
   `scripts/deploy.sh` pick up the new image automatically).
3. A short per-platform `README.md` with build/publish commands.
4. Update this document with the platform's build and publish instructions.

## Housekeeping

- Keep the "What's in the image" table in [docs/macos.md](docs/macos.md) in
  sync with the template.
- Test every image change locally before pushing — a broken image costs a
  ~1-hour rebuild.
- Name VMs exactly after images (`sandbox-macos-<macos-version>`); never
  introduce a separate naming scheme for one platform. Git release tags are
  `<platform>-v<version>` (e.g. `mac-v1.2.0`), created by `./scripts/tag.sh`.
- Keep `image_version`, `CHANGELOG.md`, and the release tag in sync — every
  release bumps the version, adds a changelog entry, and creates the tag.
