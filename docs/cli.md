# agent-dev-env CLI reference

This is the reference for the `agent-dev-env` CLI — the single tool that
builds, runs, and wires up the sandbox VMs (macOS via Tart, Windows 11
ARM64 via QEMU or VMware Fusion, Ubuntu 24.04 ARM64 via VMware) and
manages their image releases on GHCR. The per-platform guides
([macOS](macos.md), [Ubuntu](ubuntu-vmware.md),
[Windows QEMU](windows-qemu.md), [Windows VMware](windows-vmware.md)) cover
prerequisites and day-to-day usage; this document covers everything the CLI
accepts.

## Installation

The CLI is distributed as the `agent-dev-env` npm package. Use it once
without installing:

```bash
npx agent-dev-env --help
```

or install it globally:

```bash
npm install -g agent-dev-env
agent-dev-env --help
```

Contributors working in the repo can run the in-tree CLI after a build
(`pnpm build`) with the root `agent-dev-env` script:

```bash
pnpm agent-dev-env --help
```

Runtime requirements (host, macOS only):

- macOS (Apple Silicon only — Tart/QEMU/Fusion cannot virtualize ARM64
  guests on Intel).
- Node.js 20+.
- Per-platform tooling: [Tart](https://tart.run/) for `macos`
  (`brew install cirruslabs/cli/tart`), QEMU + swtpm for `windows-qemu`
  (`brew install qemu swtpm`), VMware Fusion for `windows-vmware` /
  `ubuntu-vmware` (no brew step — `vmrun` lives inside the app bundle),
  and [oras](https://oras.land/) for pulling images from GHCR
  (`brew install oras`).

`agent-dev-env doctor` checks all of this (see
[doctor](#doctor-prerequisite-and-disk-check)).

## Command overview

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

## run

Starts — and automatically wires up — the chosen sandbox VM. On first use
it picks the image (local build output first, then asks to pull `:latest`
from GHCR via `oras`), creates the working VM, boots it, bridges the host's
SSH agent and Docker engine into the guest, installs the guest-side agent
(bridges + rules), copies your host user settings where supported
(`macos`, `ubuntu-vmware`), and verifies OpenChamber. `--reset` wipes the
working VM and starts fresh from the pristine image; the pristine image is
never written to.

Platform table (defaults unless overridden — see the options/env vars
below):

| | macOS | Windows (QEMU) | Windows (VMware) | Ubuntu (VMware) |
| --- | --- | --- | --- | --- |
| Hypervisor | Tart | QEMU + HVF | VMware Fusion | VMware Fusion |
| Default image | `sandbox-macos-tahoe` | `sandbox-windows-11-arm64-qemu` | `sandbox-windows-11-arm64-vmware` | `sandbox-ubuntu-24-04-arm64-vmware` |
| Default VM | `sandbox-macos` | `sandbox-windows-11-arm64-qemu` | `agent-sandbox-windows-11-arm64-vmware` | `agent-sandbox-ubuntu-24-04-arm64-vmware` |
| Shared host dir | `--work-dir` (Tart mount) | — | skipped (unsupported for Win11 ARM) | `--work-dir` (HGFS) |
| Settings copy | yes | — | — | yes |
| Agent rules | yes | — | — | yes |
| Guest access | NAT IP:4000 | `127.0.0.1:2222` / `3389` / `4000` | NAT IP:22 / `3389` / `4000` | NAT IP:22 / `4000` |
| Agent bridge port | `4100` | `4200` | `4300` | `4400` |
| Docker bridge port | `4101` | `4201` | `4301` | `4401` |
| CPUs / RAM (default) | 8 / 16 GB | 4 / 8 GB | 4 / 8 GB | 4 / 8 GB |

Options:

- `--headless` — run without a window (`tart run --no-graphics` /
  `-display none` / Fusion `nogui`); on macOS system shortcuts are only
  captured into the guest in windowed runs.
- `--foreground` — keep the terminal attached and block until the VM
  stops (Cmd+C in the terminal stops it). Default is background: the
  command exits after the summary and the VM keeps running
  (`agent-dev-env stop <platform>` to stop it, `delete` to remove it;
  logs under the logs root, see [Paths](#paths)).
- `--no-agent` — skip the SSH agent bridge setup.
- `--no-docker` — skip the Docker engine bridge setup.
- `--no-settings` — skip copying the host user settings into the guest
  (`macos`, `ubuntu-vmware`).
- `--work-dir <path>` — host directory to share into the guest; overrides
  `SANDBOX_WORK_DIR`. macOS mounts it under
  `/Volumes/My Shared Files/<mount-name>`; Ubuntu under
  `/mnt/hgfs/work`. Skipped with a warning for `windows-vmware`
  (unsupported for Windows 11 ARM guests).
- `--reset` — delete the working VM state (working clone / COW overlay /
  TPM / EFI NVRAM) and start fresh from the pristine image. Everything
  inside the guest is lost.
- `--image <image>` — pristine image to pull/clone from
  (`SANDBOX_IMAGE`).
- `--owner <owner>` — GHCR owner for pulls (`GHCR_OWNER`; defaults to
  the git remote, then `ameshkov`).
- `--yes` — skip confirmation prompts.

The runner prints a live status line (bridges + OpenChamber) while it
works, then a summary: VM/Guest IP, shared directory, SSH agent and Docker
state, and the OpenChamber URL. After a run, the host-side bridges stay up
until `stop` (or the next `run`).

## stop

Stops the sandbox VM and kills the host bridges the runner left up.

- macOS: `tart stop` (graceful, with the legacy wait-for-stopped flow);
- QEMU: qemu via the runner's `qemu.pid` (with the overlay-path `pgrep`
  fallback), then swtpm;
- VMware: `vmrun -T fusion stop` gracefully, hard power-off fallback after
  a minute.

The guest-side bridges (launchd / systemd / ONLOGON task) stop with the VM.
Start the sandbox again with `run`.

## delete

Stops the sandbox first, then removes it:

- macOS: `tart delete` the working VM; with `--pristine` (or `--yes` at
  the pristine prompt, default no) the pristine image is deleted too.
- QEMU / VMware: removes the platform's state dir under the data root
  (extracted base + working clone, or overlay + TPM + EFI NVRAM, plus the
  pulled image cache) — the next run re-pulls the archive and re-clones.
  Fusion's VM library may still list the deleted working VM — remove the
  stale entry in the Fusion UI (harmless).

Options:

- `--yes` — do not ask for confirmation.
- `--pristine` — also delete the pristine image (macOS only).

## sync

Copies the host's user settings into the guest on demand (`macos`,
`ubuntu-vmware`) — the same files the runner copies, always, regardless of
the version marker. The VM must be running (start it with `run` first). It
restarts OpenChamber so the new settings take effect, and updates the
guest's settings marker so the runner won't re-offer the copy on its next
run. `--yes` skips the confirmation prompt. Windows platforms have no
settings step — `sync` errors helpfully there.

## status

Live status of one or all platforms: the image, whether the pristine /
working state exists, and the running state (Tart VM state, qemu pidfile
with a pgrep fallback, VMX existence + guest IP where available). With no
argument it summarizes all platforms; `status <platform>` narrows to one.

## list

Prints the images the CLI knows about (from the bundled
`dist/assets/images/*/vars/*.pkrvars.hcl` snapshot — the same images that
ship inside the npm package): name, platform, `image_version`.

## build

Builds sandbox images with Packer. Without arguments it builds every
image; pass image names to build a subset (e.g.
`agent-dev-env build sandbox-macos-tahoe windows-qemu`).

- macOS: plain `packer init` + `packer build -var-file`.
- windows-qemu: ISO + ARM64 virtio driver staging (`hdiutil`), swtpm,
  `qemu-with-tpm.sh` wrap, VNC watchdog, zstd compression of the output.
- windows-vmware: vmxnet3 driver staging from Fusion's `drivers-arm64.zip`,
  hardware upgrade of the artifact.
- ubuntu-vmware: autoinstall seed server on port 8004, watchdog-typed grub
  boot, hardware upgrade.

Outputs land under `<data>/build/<platform>/` (see [Paths](#paths)), and
the per-platform flows need `WINDOWS_ISO_PATH` / `UBUNTU_ISO_PATH` (the
ISO is bring-your-own; the CLI verifies its SHA256 from the vars file) and
— for VMware — Fusion.

Options:

- `--force` — force a rebuild (`packer -force`).
- `--no-watchdog` — skip the VNC build watchdog (it needs `vncdotool` +
  the Xcode command-line tools; builds skip it with a warning when they
  are missing).

## deploy

Pushes locally built images to GHCR after confirming the image and owner:

- macOS: `tart push --chunk-size 3` — version tag + `:latest`;
- windows-qemu: `oras push` of the qcow2 as the
  `application/vnd.agent-sandbox.qcow2` artifact;
- windows-vmware / ubuntu-vmware: pack the output into a tar.gz (vmx,
  nvram, vmdk; logs excluded) and `oras push` as
  `application/vnd.agent-sandbox.vmware-vm`.

Owner resolution: `GHCR_OWNER` env → `--owner` flag → git remote setup
(inside a checkout) → default `ameshkov`. Images live flat as
`ghcr.io/<owner>/<image>`.

Options:

- `--owner <owner>` — GHCR owner override.

## tag

Creates and pushes the annotated git release tag for an image, reading
`image_version` from the image's vars file and requiring the matching
`## [<tag>]` entry in the platform's `images/<platform>/CHANGELOG.md`
(the `<platform>-v<version>` convention, e.g. `mac-v1.2.0`). Gates: clean
worktree, tag not existing, changelog entry present. Runs from the current
checkout; `--repo <path>` overrides it. This needs a checkout of this
repository — without one it errors clearly.

## doctor

Prerequisite + disk check: host macOS, Apple Silicon, free disk (against
the images' `disk_size` vars plus the ~50 GB base image), and per-platform
tooling (tart, packer, qemu/qemu-img/swtpm, vmrun, oras) with install
hints. `--platform <platform>` narrows the check to one platform
(without it, all platforms).

## watch-build

Hidden command (`agent-dev-env watch-build <vnc-port> [outdir]`): the
foreground VNC build watchdog — polls the VNC framebuffer at the given
port, OCRs each frame with the bundled Swift helper (compiled if stale),
and answers the boot/quit prompts. Hard-errors when `vncdotool` or the
Swift compiler is missing (unlike `build`, which warns and skips).

## Environment variables

`SANDBOX_*` variables remain as fallback defaults — flags always win —
so existing invocations keep working:

| Variable | Default | What it does |
| --- | --- | --- |
| `SANDBOX_IMAGE` | per platform | Pristine image to pull/clone from (`--image`) |
| `SANDBOX_VM` | per platform | Working VM name (macOS) |
| `SANDBOX_WORK_DIR` | per platform | Host directory shared into the guest; empty disables the mount |
| `SANDBOX_MOUNT_NAME` | `dev` | Mount name in the guest (macOS: `/Volumes/My Shared Files/<name>`) |
| `SANDBOX_AGENT_PORT` | `4100`/`4200`/`4300`/`4400` | TCP port for the SSH agent bridge |
| `SANDBOX_DOCKER_PORT` | `4101`/`4201`/`4301`/`4401` | TCP port for the Docker engine bridge |
| `SANDBOX_OPENCHAMBER_PORT` | `4000` | Guest port of OpenChamber |
| `SANDBOX_SSH_PORT` | `2222` | Host port forwarded to guest SSH (`windows-qemu`) |
| `SANDBOX_RDP_PORT` | `3389` | Host port forwarded to guest RDP (`windows-qemu`) |
| `SANDBOX_WINRM_PORT` | `5985` | Host port forwarded to guest WinRM (`windows-qemu`) |
| `SANDBOX_CPU_COUNT` | per platform | CPUs for a freshly created working VM |
| `SANDBOX_MEMORY_MB` | per platform | RAM for a freshly created working VM, in MB |
| `WINDOWS_IMAGE` | — | Path to a local `sandbox-windows-11-arm64-qemu.qcow2` to run instead of the discovered/pulled one |
| `WINDOWS_VMWARE_IMAGE` | — | Path to a local Windows VMware tar.gz |
| `UBUNTU_VMWARE_IMAGE` | — | Path to a local Ubuntu tar.gz |
| `WINDOWS_PASSWORD` | from the vars file | Administrator password in the Windows guest |
| `UBUNTU_PASSWORD` | from the vars file | `admin` password in the Ubuntu guest |
| `FUSION_APP_PATH` | `/Applications/VMware Fusion.app` | VMware Fusion install location |
| `WINDOWS_ISO_PATH` | — | Windows 11 ARM64 ISO (build) |
| `VIRTIO_WIN_ISO_PATH` | — | virtio-win.iso (build; downloaded into the cache otherwise) |
| `UBUNTU_ISO_PATH` | — | Ubuntu Server ARM64 ISO (build) |
| `GHCR_OWNER` | git remote → `ameshkov` | GHCR owner for pulls/pushes |
| `NO_COLOR` | unset | Any non-empty value disables colored output |

Path overrides (see [Paths](#paths)): `AGENT_DEV_ENV_DATA_HOME`,
`AGENT_DEV_ENV_LOG_DIR`, `AGENT_DEV_ENV_CACHE_DIR` — and the `XDG_DATA_HOME`
/ `XDG_STATE_HOME` / `XDG_CACHE_HOME` equivalents (when explicitly set).

## Paths

State lives under the XDG-aware `agent-dev-env` roots (designed from
scratch — no legacy `agent-sandbox` paths, no migration):

| Role | macOS | Linux |
| --- | --- | --- |
| Data (images, working VM state, build outputs) | `~/Library/Application Support/agent-dev-env` | `~/.local/share/agent-dev-env` |
| Logs / runtime state | `~/Library/Logs/agent-dev-env` | `~/.local/state/agent-dev-env` |
| Cache (watchdog frames, downloaded ISOs) | `~/Library/Caches/agent-dev-env` | `~/.cache/agent-dev-env` |

Data layout:

```text
<data>/
  build/<platform>/            packer build outputs (built image + packer_cache
                               + staged drivers; deploy consumes these)
  build-context/<platform>/    materialized packer context (writable copy of
                               images/<platform>)
  windows-qemu/<image>/        image/ (pristine qcow2), working/ (overlay,
                               efivars.fd, tpm/, pids, sockets)
  windows-vmware/<image>/      image/, base/, working/
  ubuntu-vmware/<image>/       image/, base/, working/
```

- macOS has no data footprint: Tart owns the pristine image and the
  working VM; only the logs root (`tart-*.log`) is the CLI's.
- Guest-side markers live under `~/.config/agent-dev-env/` (settings
  version, agent-rules sha256).
- No host config file in v1 — env vars and flags only. `XDG_CONFIG_HOME`
  is a documented future hook.
