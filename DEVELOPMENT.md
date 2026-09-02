# Development Guide

This document is for people who contribute image recipes to this repository
and build/publish them with the [`agent-dev-env`](docs/cli.md) CLI.

## What is a "recipe"?

Each supported platform has a directory under `images/` containing:

1. **A Packer template** (`*.pkr.hcl`) — describes how to build the image:
   the base image it derives from, the resources of the VM, and the
   provisioning steps that install software.
2. **Variables files** (`vars/*.pkrvars.hcl`) — one file per image: the OS
   version, disk size and the image's semantic version.
3. **A README.md and a CHANGELOG.md** — per-platform image docs and history.

The build/publish/deploy flows (`build`, `deploy`, `tag`,
`watch-build`) are implemented in the CLI
(`packages/agent-dev-env-cli/src/lifecycle/`) and ship inside the npm
package — no shell scripts, no repo checkout needed for `build`/`deploy`.
The running side of a recipe (how to run the VM, share directories, the SSH
agent bridge, etc.) lives in the per-OS user guides under [docs/](docs/) —
keep them in sync whenever you change how an image behaves.

## Repository layout

```text
├── README.md                      # Index: point of entry to all docs
├── DEVELOPMENT.md                # This document
├── docs/                          # User-facing, per host OS setup guides
│   ├── cli.md                     # agent-dev-env CLI reference
│   ├── macos.md                   # macOS (Apple Silicon) — pull & run, details
│   ├── ubuntu-vmware.md           # Ubuntu 24.04 (ARM64) guest under VMware Fusion — run, details
│   ├── windows-qemu.md            # Windows 11 (ARM64) guest under QEMU — run, details
│   ├── windows-vmware.md          # Windows 11 (ARM64) guest under VMware Fusion — run, details
│   ├── ssh-agent.md               # share the host's SSH agent with the guest
│   └── plan.md                    # the design document of the CLI port
├── assets/                        # runtime assets bundled into the npm package
│   ├── rules/                     # agent-rules.md, agent-rules-linux.md
│   └── watchdog/                  # watch-build.py, watch-build-ocr.swift
├── packages/                      # pnpm workspace packages
│   ├── agent-dev-env-cli/         # the agent-dev-env CLI (published to npm)
│   ├── bridge-core/               # zero-dep socket forwarder (bundled internally)
│   ├── guest-rules/               # shared agent-rules probe/apply logic
│   ├── guest-agent-mac/           # macOS guest agent (bundled internally)
│   ├── guest-agent-windows/       # Windows 11 ARM64 guest agent (bundled internally)
│   └── guest-agent-ubuntu/        # Ubuntu guest agent (bundled internally)
├── build/                         # <data>/build/<platform>/ — per-platform build
│                                  # artifacts (gitignored; see "Build outputs")
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
    │   ├── qemu-with-tpm.sh       # qemu_binary wrapper (TPM/USB/CD wiring; packaged asset)
    │   ├── README.md
    │   ├── CHANGELOG.md
    │   └── vars/
    │       └── sandbox-windows-11-arm64-qemu.pkrvars.hcl
    ├── windows-arm64-vmware/      # Windows 11 (ARM64) guest images, VMware (host: Apple Silicon)
    │   ├── sandbox.pkr.hcl        # Packer template (vmware-iso plugin)
    │   ├── autounattend.xml       # Windows unattended install config
    │   ├── README.md
    │   ├── CHANGELOG.md
    │   └── vars/
    │       └── sandbox-windows-11-arm64-vmware.pkrvars.hcl
    └── ubuntu-arm64-vmware/       # Ubuntu 24.04 (ARM64) guest image, VMware (host: Apple Silicon)
        ├── sandbox.pkr.hcl        # Packer template (vmware-iso plugin)
        ├── autoinstall/           # Subiquity autoinstall seed: user-data + meta-data (served over HTTP)
        ├── README.md
        ├── CHANGELOG.md
        └── vars/
            └── sandbox-ubuntu-24-04-arm64-vmware.pkrvars.hcl
```

## Build outputs

`agent-dev-env build` materializes the packer context and writes outputs
under the CLI's data root — `<data>/build/<platform>/` (on macOS
`~/Library/Application Support/agent-dev-env/build/`; override with
`AGENT_DEV_ENV_DATA_HOME`). Per-image artifacts (`output/`, `packer_cache/`,
`drivers/staging/`, watchdog frames) live there:

- macOS (Tart) images build no files — the `tart` builder leaves the VM in
  the Tart store (`~/.tart/vms/`), so macOS has no build directory.
- windows-qemu: `output/sandbox-windows-11-arm64-qemu.qcow2` (zstd).
- windows-vmware: `output/sandbox-windows-11-arm64-vmware.{vmx,vmdk,etc}`.
- ubuntu-vmware: `output/sandbox-ubuntu-24-04-arm64-vmware.{vmx,vmdk,etc}`.

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
     utilities (`brew_formulas` variable — includes `socat` for the CLI
     toolchain, see [docs/macos.md](docs/macos.md), and the Docker CLI
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
# From the repository root
npx agent-dev-env build sandbox-macos-tahoe
```

Without an argument, `agent-dev-env build` builds every image in
`images/*/vars/`. Pass image names to build just those.

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
4. Build locally (`npx agent-dev-env build sandbox-macos-sequoia`) and make
   sure it works.
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
npx agent-dev-env deploy sandbox-macos-tahoe
```

`agent-dev-env deploy` without an argument pushes every image. The GHCR owner
resolution: `GHCR_OWNER` env → `--owner` flag → git remote (inside a
checkout) → default `ameshkov`.

The first push of an image creates a new GHCR package, and GitHub does
**not** link it to this repository automatically. After the first
`deploy` run, open the package settings page
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
   npx agent-dev-env tag sandbox-macos-tahoe
   ```

   `tag` reads `image_version` from the vars file, verifies the working
   tree is clean and that the `[<tag>]` entry exists in the changelog, and
   creates an annotated `<platform>-v<version>` tag on the release commit
   (e.g. `mac-v1.2.0`), then pushes it to origin. The changelog's tag links
   resolve to it. This needs a checkout of the repo (`--repo <path>`
   overrides the current one).
6. Build the image locally (`npx agent-dev-env build <image-name>`) and
   push the new version tag plus `:latest` to GHCR with
   `npx agent-dev-env deploy <image-name>` (see "Publishing" above).

Note: the CLI version (`package.json`) and the image `image_version`s bump
together in one release.

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
    tooling (Node.js in-image relays; the host side is the CLI's own
    bridge forwarder — no socat — see docs/windows-qemu.md). Finishes
    with hardening (Defender realtime scan, telemetry/indexer services,
    hibernation), a version banner, and cleanup.
4. Leaves a qcow2 disk image at
   `~/Library/Application Support/agent-dev-env/build/windows-qemu/output/sandbox-windows-11-arm64-qemu.qcow2`,
   compressed with zstd.

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
  npx agent-dev-env build sandbox-windows-11-arm64-qemu
```

The windows-qemu flow verifies the ISO against `iso_sha256` from the vars
file, downloads virtio-win.iso into the build cache when
`VIRTIO_WIN_ISO_PATH` is unset, stages the ARM64 driver subset into
`drivers/staging/` (packed into the unattend CD — WinPE drive letters on
ARM64 are non-deterministic, so a separate drivers CD is unreliable),
starts `swtpm`, wraps packer's qemu binary with `qemu-with-tpm.sh`, runs
the VNC build watchdog, and zstd-compresses the output. A build takes
roughly 30 minutes on an M-series Mac.

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
   NIC driver (inf/sys/cat), extracted by the build flow from the Fusion
   app bundle
   (`Contents/Library/isoimages/arm64/drivers-arm64.zip`) into
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
   times out. The tools are what make `vmrun getGuestIPAddress` work at
   runtime (HGFS shared folders are not supported for Windows 11 ARM
   guests on Apple silicon — see docs/windows-vmware.md).
4. **Leaves a runnable vmx + vmdk** at
   `~/Library/Application Support/agent-dev-env/build/windows-vmware/output/sandbox-windows-11-arm64-vmware.vmx`
   (disk type 0, monolithic sparse; no build-time snapshot — the runner
   makes a full `vmrun clone` as the working VM). `build` then upgrades the
   VM to the hardware version the installed Fusion writes for a new VM
   (`vmrun upgradevm`): the builder's level 20 VM would show a one-time
   "Upgrade this virtual machine?" prompt on the first GUI start under a
   newer Fusion (22 on Fusion 26). The runner upgrades its working clone
   the same way, so artifacts built by older Fusion versions start clean
   too.

Prerequisites: macOS + Apple Silicon, VMware Fusion 13.6+ (free for
personal use), Packer, and the same bring-your-own Windows 11 ARM64 ISO
(`WINDOWS_ISO_PATH`). Build:

```bash
WINDOWS_ISO_PATH=/path/to/Win11_25H2_English_Arm64_v2.iso \
  npx agent-dev-env build sandbox-windows-11-arm64-vmware
```

The runtime side is `agent-dev-env run windows-vmware` — no port
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
VNC server to port 5901 and `build` starts the bundled watchdog
(`assets/watchdog/watch-build.py`) around `packer build`: it polls the VNC
framebuffer, OCRs each frame with Apple Vision
(`assets/watchdog/watch-build-ocr.swift`, compiled on first use), and

- clicks "No" on the quit-confirmation dialog (at the OCR'd button
  position, with a fallback for the 800x600 framebuffer),
- presses a key when "Press any key to boot from CD or DVD" is on screen,
- boots the ISO from the UEFI shell (`fs0:` + `EFI\BOOT\BOOTAA64.EFI`).

The Python supervisor runs every capture in a subprocess with a hard
timeout, so a hung VNC/OCR cycle cannot stall the watch. Prerequisites:
`pip3 install vncdotool` + the Xcode command line tools; `build` skips the
watchdog with a warning when they are missing (`--no-watchdog` skips it
explicitly). Frames and logs land in
`~/Library/Application Support/agent-dev-env/build/<platform>/packer_cache/watchdog/`.
`agent-dev-env watch-build <vnc-port> [outdir]` runs the same watchdog in
the foreground (with hard errors for missing prerequisites).

### Template variables

| Variable | Type | Default | Description |
| --- | --- | --- | --- |
| `windows_version` | string | — | Windows guest version, e.g. `11`; part of the image name (`sandbox-windows-<windows_version>-arm64-qemu` / `-arm64-vmware`) |
| `image_version` | string | — | Semantic version this image is published under; bump it + add a `CHANGELOG.md` entry per release |
| `iso_path` | string | — | Absolute path to the Windows 11 ARM64 ISO (set by the build flow, not in the vars file) |
| `iso_sha256` | string | `` | SHA256 of the Windows ISO (verified by the build flow; empty = skip) |
| `virtio_win_iso_path` | string | — | Path to virtio-win.iso (set by the build flow) |
| `virtio_win_url` | string | stable URL | Download URL used by the build flow when `VIRTIO_WIN_ISO_PATH` is unset |
| `virtio_win_sha256` | string | `` | SHA256 of virtio-win.iso (verified by the build flow; empty = skip) |
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
| `vnc_bind_address` / `vnc_port_min` / `vnc_port_max` | string/number | `127.0.0.1` / `5901` / `5901` | VNC server for the build watchdog (pinned so `build` can start it without scanning for the port) |

### Publishing

The macOS images are pushed with `tart push`; the Windows images are plain
files (qcow2 / vmx+vmdk tar.gz), so `deploy` pushes them to GHCR as OCI
artifacts with `oras`:

```bash
# From the repository root; needs `brew install oras` and a GHCR token
# with write:packages (`oras login ghcr.io`)
npx agent-dev-env deploy sandbox-windows-11-arm64-qemu
npx agent-dev-env deploy sandbox-windows-11-arm64-vmware
```

This pushes `ghcr.io/<owner>/<image>:<image_version>` and `:latest` for
each. Consumers pull the file back by its name, e.g.
`agent-dev-env run windows-qemu` runs `oras pull` into its state dir when
no local build output exists (the VMware runner does the same for the
tar.gz).

## Ubuntu images

### How they are built

`images/ubuntu-arm64-vmware/sandbox.pkr.hcl` reuses the
[vmware-iso mechanics of the Windows VMware image](#vmware-images-imageswindows-arm64-vmware)
(Fusion on Apple Silicon, `guest_os_type "arm-ubuntu-64"`, hardware
version 20, NVMe disk, vmxnet3 NIC under NAT, EFI firmware, headless with
VNC pinned to 5901) with a Linux installer: Ubuntu Server 24.04 ARM64 is
autoinstalled by Subiquity, not unattended:

1. **The boot is typed by the build watchdog, not the Packer
   boot_command.** The firmware's No-Media/PXE probe cycle before grub
   appears is variable-length (measured 20-40 s on Fusion), so plugin
   typing fired before grub was up and the menu's default entry booted
   the interactive installer. `assets/watchdog/watch-build.py` (with the
   `WATCH_BUILD_BOOT_CMD` env var, rendered by the ubuntu-vmware flow)
   detects the grub menu/shell in the VNC OCR and types the autoinstall
   kernel line `linux /casper/vmlinuz autoinstall
   ds=nocloud-net;s=http://<vmnet8-host>:8004/ ---` (the seed server is
   `python3 -m http.server 8004` over `autoinstall/`, started by the
   build flow; the plugin's own http_directory uses a random port and
   does not accept an `http_port` override). While the command is untyped
   the watchdog polls every 3 s — grub's menu countdown is only ~20 s
   wide, and the watchdog's slow cadence (90 s worker + 20 s sleep ≈ one
   frame per ~2 min) could miss the menu so completely that the
   interactive Subiquity installer booted and the build hung on "Timeout
   waiting for SSH" (observed on 2026-08-29); once `.boot-typed` exists
   (or after a 4 min cap) the slow cadence resumes. Subiquity then
   configures LVM over the whole disk, user `admin` (password hash — keep
   in sync with `ssh_password` in the vars file), openssh-server with
   password auth, open-vm-tools — and reboots into the installed system.
2. **No Fusion driver/tools staging** — the vmxnet3 NIC driver ships in
   Ubuntu's base `linux-modules` package (verified for 24.04 arm64; NVMe
   is in-box too), and Fusion ships *no* Linux tools ISO for arm64 guests
   (`isoimages/arm64/` has only `windows.iso`), so open-vm-tools come from
   the Ubuntu archive. open-vm-tools are what make `vmrun
   getGuestIPAddress` and HGFS work at runtime.
3. **Provisions over SSH** — the same toolchain story as the other
   sandboxes: apt base toolchain (build-essential, git, curl, jq,
   ripgrep, vim, tmux, socat, python3, ruby; browser/X libs), hash-pinned
   direct downloads (GitHub CLI deb, Go tarball, VS Code deb, Chrome for
   Testing zip, Firefox release tarball, Docker CLI + compose + buildx
   static binaries), nvm (Node), rustup (Rust), and npm globals
   (opencode-ai, ocr, @openchamber/web). The guest also ships a desktop:
   `ubuntu-desktop-minimal` + `open-vm-tools-desktop`, `graphical.target`
   as the default boot target and GDM3 auto-login as `admin` (Xorg
   session — software rendering, a Fusion arm64 guest has no GPU accel).
   OpenChamber runs as a systemd **user** service
   (`agent-sandbox-openchamber`) on `0.0.0.0:4000` with
   `loginctl enable-linger` — the Linux equivalent of the macOS
   LaunchAgent / Windows ONLOGON task.
4. **Leaves a runnable vmx + vmdk** at
   `~/Library/Application Support/agent-dev-env/build/ubuntu-vmware/output/sandbox-ubuntu-24-04-arm64-vmware.vmx`
   (disk type 0, monolithic sparse; no build-time snapshot — the runner
   makes a full `vmrun clone` as the working VM). `build` then upgrades
   the VM to the hardware version the installed Fusion writes for a new VM
   (`vmrun upgradevm` — same rationale as the Windows image).

The runtime side is `agent-dev-env run ubuntu-vmware` — same mechanics as
the Windows VMware runner (NAT + vmnet8, guest IP via open-vm-tools, no
port forwarding), with Linux guests: the bridges are systemd **user**
services (installed by the bundled `guest-agent-ubuntu`, services persist
via linger), the shared folder mounts at `/mnt/hgfs/work`, and the runner
also installs the sandbox agent rules (`assets/rules/agent-rules-linux.md`).
Bridge ports: SSH agent **4400**, Docker **4401** (macOS 4100/4101, QEMU
4200/4201, Windows VMware 4300/4301 — all four sandboxes can run side by
side).

### Prerequisites (local builds)

- macOS host with **Apple Silicon** (Fusion cannot run ARM64 guests on
  Intel).
- [VMware Fusion](https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion)
  13.6+ (free for personal use).
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`
  (the VMware plugin is installed automatically by `packer init`).
- The Ubuntu Server 24.04 ARM64 ISO (see
  `images/ubuntu-arm64-vmware/README.md` for the download steps) —
  `UBUNTU_ISO_PATH` must be set when building.

### Building an image

```bash
# From the repository root; the ISO is required
UBUNTU_ISO_PATH=/path/to/ubuntu-24.04.4-live-server-arm64.iso \
  npx agent-dev-env build sandbox-ubuntu-24-04-arm64-vmware
```

The ubuntu-vmware flow verifies the ISO against `iso_sha256` from the vars
file, serves the autoinstall seed on port 8004, types the grub command via
the VNC build watchdog (vmnet8 subnet from Fusion's dhcpd.conf), runs
`packer init` + `packer build`, and upgrades the output VM with `vmrun
upgradevm`. A build takes roughly 20 minutes on an M-series Mac; everything
per image lives in `~/Library/Application Support/agent-dev-env/build/ubuntu-vmware/`.

### Template variables

| Variable | Type | Default | Description |
| --- | --- | --- | --- |
| `ubuntu_version` | string | — | Ubuntu guest version, e.g. `24-04`; part of the image name (`sandbox-ubuntu-<ubuntu_version>-arm64-vmware`) |
| `image_version` | string | — | Semantic version this image is published under; bump it + add a `CHANGELOG.md` entry per release |
| `iso_path` | string | — | Absolute path to the Ubuntu Server ARM64 ISO (set by the build flow, not in the vars file) |
| `iso_sha256` | string | `` | SHA256 of the Ubuntu ISO (verified by the build flow; empty = skip) |
| `ssh_username` | string | `admin` | SSH provisioning user; must match `autoinstall/user-data` |
| `ssh_password` | string | `sandbox1` | SSH provisioning password; must match the crypt hash in `autoinstall/user-data` |
| `node_version` / `python_version` | string | `22` / `3.12` | Node major (nvm) and Python (apt archive) versions |
| `github_cli_version` / `go_version` / `rust_version` / `vscode_version` / `chrome_version` / `firefox_version` / `open_code_review_version` | string | pinned | Pinned toolchain versions (+ SHA256 vars for the direct downloads) |
| `docker_version` / `docker_compose_version` / `docker_buildx_version` | string | pinned | Docker CLI + plugin versions (+ SHA256 vars) |
| `disk_size` | number | `100` | VM disk size in GB |
| `cpu_count` | number | `4` | CPU count of the VM |
| `memory_gb` | number | `8` | RAM of the VM in GB |
| `openchamber_ui_password` | string | `sandbox` | Password protecting the OpenChamber web UI |
| `openchamber_port` | number | `4000` | TCP port of the OpenChamber web UI in the guest |

### Publishing

Same as the Windows VMware image: `deploy` packs the output directory into
a tar.gz and pushes it to GHCR as an OCI artifact with `oras`:

```bash
# From the repository root; needs `brew install oras` and a GHCR token
# with write:packages (`oras login ghcr.io`)
npx agent-dev-env deploy sandbox-ubuntu-24-04-arm64-vmware
```

This pushes `ghcr.io/<owner>/<image>:<image_version>` and `:latest`.
Consumers pull the file back by its name (`agent-dev-env run ubuntu-vmware`
runs `oras pull` into its state dir when no local build output exists).
Release tags are `ubuntu-arm64-vmware-v<version>`
(`npx agent-dev-env tag <image>`).

## Adding a new platform

To add a new host/guest combination (e.g. macOS host → FreeBSD guest),
create a new `images/<platform>/` directory following the macOS pattern:

1. Packer template with the appropriate builder (e.g. QEMU, or the
   [qocker](https://github.com/AdGuardSoftwareLimited/qocker) Vmfile approach
   for layered Linux images). If the platform needs host-side preparation
   that plain `packer build` cannot do (like the Windows ISO staging and
   swtpm), extend the CLI's lifecycle with a `build-<platform>.ts` flow —
   `lifecycle/build.ts` dispatches to it automatically by platform
   metadata (`lib/platform.ts`). If it needs a different push mechanism
   (like the Windows qcow2 vs Tart VMs), extend `lifecycle/deploy.ts`.
2. `vars/` image files + a `CHANGELOG.md` (the CLI's catalog picks up the
   new image automatically).
3. A short per-platform `README.md` with build/publish commands.
4. Update this document with the platform's build and publish instructions.

## Housekeeping

- Keep the "What's in the image" tables in [docs/macos.md](docs/macos.md)
  (and the platforms' `README.md`, e.g.
  [images/ubuntu-arm64-vmware/README.md](images/ubuntu-arm64-vmware/README.md)
  and [docs/ubuntu-vmware.md](docs/ubuntu-vmware.md)) in sync with the
  templates.
- Test every image change locally before pushing — a broken image costs a
  ~1-hour rebuild.
- Name VMs exactly after images (`sandbox-macos-<macos-version>`,
  `sandbox-windows-<version>-arm64-<platform>`,
  `sandbox-ubuntu-<version>-arm64-vmware`); never introduce a separate
  naming scheme for one platform. Git release tags are
  `<platform>-v<version>` (e.g. `mac-v1.2.0`), created by
  `agent-dev-env tag`.
- Keep `image_version`, `CHANGELOG.md`, and the release tag in sync — every
  release bumps the version, adds a changelog entry, and creates the tag.
- The CLI and image versions bump together in one release
  (`package.json` + the images' vars files).
