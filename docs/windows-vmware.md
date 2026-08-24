# Set up a VMware Windows sandbox (Apple Silicon)

> **What you'll get.** A local sandbox virtual machine: a Windows 11 (ARM64)
> guest with a full coding toolchain and an AI coding agent (OpenCode)
> pre-installed, plus the OpenCodeReview code-review CLI and the OpenChamber
> web UI to run and supervise agent sessions from your host browser — running
> under VMware Fusion on your Apple Silicon Mac. A host directory can be
> shared into the guest (`--work-dir`), and the guest is reachable directly
> at its NAT IP (no port forwarding).
>
> **Quick setup** — three steps and you're done:
>
> 1. [Install VMware Fusion](#1-install-vmware-fusion)
> 2. [Run the sandbox](#2-run-the-sandbox)
> 3. [Use the sandbox](#3-use-the-sandbox)
>
> Everything below the **Details** divider is optional reading: what's inside
> the image and how the pieces fit together.

## Which Windows sandbox?

This is the VMware (Fusion) variant. It exists alongside the
[QEMU-based Windows sandbox](windows.md):

| | VMware (this guide) | QEMU |
| --- | --- | --- |
| Hypervisor | VMware Fusion (free) | QEMU + HVF |
| Performance | Near-native | Near-native |
| Guest tools | VMware Tools (in-image) | virtio drivers |
| Shared host folder | Yes (HGFS, `--work-dir`) | No |
| Extra tools | Fusion only | qemu + swtpm |
| Publish artifact | vmx + vmdk (tar.gz) | qcow2 |

Both images install the same Windows 11 Pro ARM64 guest and toolchain; pick
either. Fusion is the better fit if you want a shared folder or already
use Fusion; QEMU needs no extra VMware install.

## Quick setup

### Prerequisites

- An Apple Silicon Mac (M1 or newer). Fusion cannot virtualize ARM64 guests
  on Intel, so this sandbox is ARM64-only.
- [VMware Fusion](https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion)
  (free for personal use; the image is built against Fusion 13.6+).
- ~40 GB of free disk space (the image is ~20 GB, the working clone grows on
  top).

### Default account

Every sandbox guest has a single local user, used for SSH and RDP:

| User | Password |
| --- | --- |
| `Administrator` | `sandbox1` |

### 1. Install VMware Fusion

Download and install Fusion from the link above (free for personal use —
create a free Broadcom account if prompted). No license key is needed for
personal use. The runner talks to it through `vmrun`, which is inside the
app bundle — no `brew` step.

### 2. Run the sandbox

The repo ships a runner script that extracts the image, clones a working
VM, and wires up the bridges. From the repo root:

```bash
./scripts/run-windows-vmware-sandbox.sh
```

On first use it picks the image archive: the local build output
(`build/windows-arm64-vmware/output/sandbox-windows-11-vmware.tar.gz`)
when present, otherwise it asks to pull `sandbox-windows-11-vmware:latest`
from GHCR via [oras](https://oras.land/) (one-time, ~20 GB —
`brew install oras`). It then extracts the pristine VM and clones a
working VM under
`~/Library/Application Support/agent-sandbox/windows-11-vmware` — the
pristine image is never written to. On the first clone the runner also
upgrades the working VM's virtual hardware to the version your Fusion
supports (`vmrun upgradevm`, recorded once per clone) — without it a
newer Fusion shows its one-time "Upgrade this virtual machine?" dialog on
the first windowed start. The guest boots headless or in a
Fusion window (default), and the runner discovers its NAT IP via VMware
Tools:

| Port | Guest service |
| --- | --- |
| 22 | SSH |
| 3389 | RDP |
| 4000 | OpenChamber web UI |
| 5985 | WinRM (advanced use) |

No port forwarding is needed: the VM sits on Fusion's NAT network
(vmnet8), and the host is that network's router, so the guest IP the
runner prints is reachable directly from the host. When a Docker engine
is running on the host (Docker Desktop, Colima, OrbStack, ...), the
runner bridges it into the guest; same for a password-manager SSH agent
(see [Docker (remote engine)](#docker-remote-engine) and
[SSH agent bridge](#ssh-agent-bridge)). On the very first run the runner
also offers to enable Windows' auto-logon and reboot the guest once — the
image ships with auto-logon disabled after the OOBE boot, and the
OpenChamber web UI only starts at logon (see
[OpenChamber from the host](#openchamber-from-the-host)).

A Fusion window opens and the guest logs in automatically. Pass
`--foreground` to keep the terminal attached (Cmd+C stops the VM),
`--headless` to run without a window, `--no-agent` / `--no-docker` to
skip a bridge, `--work-dir /path` to share a host folder, or `--reset`
to wipe the working VM and start fresh from the pristine image.

> [!NOTE]
> The working VM is your sandbox: installs, config, and agent state
> accumulate in the clone and survive restarts. `--reset` deletes the
> clone — everything inside the guest is lost; the pristine image is not
> touched.

### 3. Use the sandbox

The runner prints the guest IP (or find it anytime with
`vmrun -T fusion getGuestIPAddress <vmx>`). Everything is set up now —
use it from the host or inside the VM:

- **Browser UI (OpenChamber)**: open `http://<guest-ip>:4000/` on the host
  (default password: `sandbox`) and start or supervise agent sessions — see
  [OpenChamber from the host](#openchamber-from-the-host).
- **Desktop (RDP)**: connect to `<guest-ip>:3389` with Microsoft Remote
  Desktop (or any RDP client), user `Administrator` / `sandbox1`. The guest
  desktop has VS Code, Chrome, Firefox, and a Terminal.
- **Terminal (OpenCode)**: over SSH from the host:

  ```bash
  ssh Administrator@<guest-ip>
  ```

  Then configure the agent's LLM provider once (see
  [Configure the environment](#configure-the-environment)) and start it:

  ```powershell
  opencode
  ```

- **Code review (OpenCodeReview)**: the image ships the `ocr` CLI — see the
  [OpenCodeReview quick start](https://github.com/alibaba/open-code-review#quick-start).
- **Shared folder**: if you passed `--work-dir /path`, the folder is
  available in the guest at `\\vmware-host\Shared Folders\work` — map it to
  a drive letter in the guest, or use it from PowerShell/VS Code directly.

### Configure the environment

The coding agent (OpenCode) needs an LLM provider before it can work. Over
SSH or in the guest's PowerShell, add yours:

```powershell
opencode providers login
```

This walks you through the provider setup (API key, model, ...). Once
configured, restart OpenChamber so it picks up the provider:

```powershell
openchamber restart
```

### Everyday commands

- **Stop the sandbox** — from the host:

  ```bash
  vmrun -T fusion stop "$HOME/Library/Application Support/agent-sandbox/windows-11-vmware/working/sandbox-windows-11-vmware.vmx"
  ```

  Start it again with `./scripts/run-windows-vmware-sandbox.sh`.

- **Reset the sandbox** — wipe the working VM and start from the pristine
  image:

  ```bash
  ./scripts/run-windows-vmware-sandbox.sh --reset
  ```

- **Run several sandboxes side by side** — set `SANDBOX_STATE_DIR` to a
  different directory (the guest IPs differ per NAT lease; the runner
  prints them).

---

## Details

### What's in the image

The image is built with [Packer](https://www.packer.io/)'s VMware plugin
(`vmware-iso`) from the official Windows 11 ARM64 ISO (bring-your-own, see
[images/windows-arm64-vmware/README.md](../images/windows-arm64-vmware/README.md))
and runs under Fusion via `vmrun`. It ships:

| Component | Detail |
| --- | --- |
| Windows 11 Pro (ARM64) | Unactivated (watermark); generic Pro key used for Setup |
| VMware Tools | ARM64 tools (from the Fusion install); enables guest IP discovery + shared folders |
| VMware drivers | vmxnet3 ARM64 NIC driver; NVMe disk uses the in-box driver |
| Chocolatey | Community package manager (versions pinned in the vars file) |
| Node.js, Python, Git, gh, ripgrep, jq, curl | Choco packages (versions from the vars file) |
| Go, Vim, NuGet, make, MinGW-w64 | Choco packages (versions from the vars file) |
| Rust | Via rustup (arm64 host toolchain + MSVC targets), `rust`/`cargo` on PATH |
| VS2022 Build Tools | Choco + `setup.exe` finalizer: .NET 4.8/.NET Core SDKs, VC++ workload (x86/x64/ARM/ARM64), CMake, Windows 11 SDK |
| WiX, protoc, NASM, LLVM | Choco packages (versions from the vars file) |
| Visual Studio Code | Native arm64 build, latest stable, direct download; `code` on PATH |
| Google Chrome | Chrome for Testing snapshot (hash-pinned), x64 under emulation |
| Firefox | Choco package (x64, runs under emulation) |
| OpenCode (`opencode-ai`) | npm global |
| OpenCodeReview (`ocr`) | npm global (`@alibaba-group/open-code-review`) |
| OpenChamber web UI | npm global (`@openchamber/web`), scheduled task on `0.0.0.0:4000` |
| OpenSSH Server + RDP | Enabled; Administrator/sandbox1 (see the vars file) |
| Docker CLI | Client only (`docker` + `docker compose`), remote engine via the host bridge |
| Bridge tooling | Node.js (in-image) relays + host socat for the SSH-agent/Docker bridges |

Verify the toolchain over SSH (`ssh Administrator@<guest-ip>`, password
`sandbox1`):

```powershell
node --version && npm --version
python --version
git --version
gh --version
rg --version
jq --version
go version
rustc --version && cargo --version
protoc --version
code --version
opencode --version
ocr --version
openchamber --version
docker --version
docker compose version
```

### OpenChamber from the host

[OpenChamber](https://openchamber.dev) is the web UI for OpenCode: start
sessions, supervise them, review changes — all from your host browser. The
image installs it as a scheduled task (`dev.openchamber.web`) that starts at
**logon**, listening on `0.0.0.0:4000`. The guest's IP is reachable directly
from the host, so with the VM running:

```bash
open "http://<guest-ip>:4000"
```

The default UI password is `sandbox`. Notes:

- Because the task fires at logon, the guest must be logged in. The runner
  enables Windows' auto-logon on first use (with your confirmation) so the
  guest logs itself in at boot and the UI comes up without interaction. The
  image's `autounattend.xml` deliberately sets `LogonCount=1` — one OOBE
  auto-login only — which is why the runner re-enables it.
- The UI binds to `0.0.0.0` inside the guest, which is only reachable over
  Fusion's NAT segment (vmnet8) — not your LAN (unless you bridge the guest
  network manually).
- `openchamber status` and `openchamber logs` (from the guest) help when
  something is off.

### Docker (remote engine)

The image ships the **Docker CLI** but no local engine: a Windows guest
cannot run a hypervisor (no nested virtualization through Fusion), so
Docker Desktop / WSL2 inside the sandbox would fail their hypervisor
checks — the same constraint as the macOS guest. The CLI works as-is
against any remote engine.

**The runner wires the host's engine into the guest automatically.** When a
Docker engine socket is found on the host (Docker Desktop at
`~/.docker/run/docker.sock`, Colima, OrbStack, or `/var/run/docker.sock`),
it bridges it: a host-side `socat` exposes the socket on TCP `4301`
(bound to the host's vmnet8 address — reachable from the guest), and a
guest-side Node relay (served by the image's `node.exe`) presents it as
the `\\.\pipe\docker_engine` named pipe — the exact pipe Docker on Windows
looks for by default. A docker context named `host` is created and made the
default, so `docker`, `docker compose`, and docker clients that read the
default pipe all hit the host engine:

```powershell
# inside the guest — the runner already set up the context
docker context show          # host
docker run --rm hello-world
```

Notes:

- Containers run on the **host engine**, so published ports are bound on
  the host. From inside the guest they are reachable at the host's NAT
  address (the guest's default gateway — Fusion's NAT runs in userspace,
  so there is no vmnet8 interface on the host), *not* `localhost`.
- The bridge survives guest reboots (an ONLOGON scheduled task restarts the
  relays at logon) and the host side reconnects on the next run of the
  runner. The host listener binds to the vmnet8 address only — the engine
  is not exposed to your LAN.
- The engine must be running when the runner bridges it. If Docker Desktop
  isn't started yet, the runner skips the bridge — start the engine and
  re-run the script (the setup is idempotent).
- Pass `--no-docker` to skip; `SANDBOX_DOCKER_PORT` overrides the bridge
  port (default `4301`; QEMU uses `4201`, macOS `4101`, so all three
  sandboxes can run side by side).
- Container-based test frameworks (testcontainers and similar) work out of
  the box: on Windows they dial the default named pipe, which *is* the
  bridged engine.

### SSH agent bridge

The runner also bridges a password-manager SSH agent (Bitwarden, 1Password,
...) into the guest: a host-side `socat` turns the agent socket into TCP
`4300` on the host's NAT address (the guest's default gateway), and a
guest-side Node relay serves it as the
`\\.\pipe\openssh-ssh-agent` named pipe. The guest's `SSH_AUTH_SOCK`
environment variable points at that pipe, so `ssh`/`git` inside the guest
authenticate with the host's keys — no keys are copied into the guest.

Notes:

- Only an *overridden* agent is bridged (when `SSH_AUTH_SOCK` points at a
  password manager's socket). The stock macOS launchd agent is not bridged.
- The host listener lives only for the run (it stays up in background mode
  until killed); the guest side persists via the ONLOGON task.
- Pass `--no-agent` to skip; `SANDBOX_AGENT_PORT` overrides the bridge port
  (default `4300`; QEMU uses `4200`, macOS `4100`).

### Shared host folder

Unlike the QEMU sandbox, the VMware image ships VMware Tools, so a host
directory can be shared into the guest (HGFS). Pass `--work-dir` on the
runner:

```bash
./scripts/run-windows-vmware-sandbox.sh --work-dir "$HOME/projects"
```

The folder appears in the guest at `\\vmware-host\Shared Folders\work` —
map it to a drive letter (`net use W: \\vmware-host\Shared Folders\work`)
for everything to see it. Notes:

- Best-effort: the runner warns and continues when the share could not be
  registered (e.g. tools not fully up yet). Re-run the runner afterwards.
- The share is read/write. Use git, RDP clipboard, or the OpenChamber UI
  as the alternative transport (see the QEMU guide).

### Runner script reference

[`scripts/run-windows-vmware-sandbox.sh`](../scripts/run-windows-vmware-sandbox.sh)
is the automated way to boot, run, and wire up the sandbox. Everything it
accepts:

Options:

- `--headless` — run without a window
- `--foreground` — keep the terminal attached and block until the VM stops
  (Cmd+C stops it). Default is background: the script exits after the
  summary and the VM keeps running
- `--no-agent` — skip the SSH agent bridge setup
- `--no-docker` — skip the Docker engine bridge setup
- `--work-dir PATH` — share the host directory into the guest as
  `\\vmware-host\Shared Folders\work` (VMware Tools HGFS)
- `--reset` — delete the working VM state (extracted base + clone) and
  start fresh from the pristine image

Environment variables (defaults in parentheses):

| Variable | Default | What it does |
| --- | --- | --- |
| `WINDOWS_VMWARE_IMAGE` | — | Path to a local `sandbox-windows-11-vmware.tar.gz` to run instead of the discovered/pulled one |
| `SANDBOX_STATE_DIR` | `~/Library/Application Support/agent-sandbox/windows-11-vmware` | Working VM state (extracted base + clone) |
| `WINDOWS_PASSWORD` | from the vars file | Administrator password in the guest (override after changing it) |
| `SANDBOX_OPENCHAMBER_PORT` | `4000` | Guest port of OpenChamber |
| `SANDBOX_AGENT_PORT` | `4300` | TCP port for the SSH agent bridge |
| `SANDBOX_DOCKER_PORT` | `4301` | TCP port for the Docker engine bridge |
| `GHCR_OWNER` | from the git remote | GHCR owner used when pulling the image |
| `NO_COLOR` | unset | Any non-empty value disables colored output |
| `FUSION_APP_PATH` | `/Applications/VMware Fusion.app` | VMware Fusion install location |

## Building your own images

This repository is also a collection of image recipes. See
[DEVELOPMENT.md](../DEVELOPMENT.md) for how to build the Windows image
locally (the ISO is bring-your-own) and publish it to GHCR.
