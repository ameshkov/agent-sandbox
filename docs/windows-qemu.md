# Set up a Windows sandbox (Apple Silicon)

> **Prefer VMware?** This guide is the QEMU-based sandbox. A VMware
> (Fusion) variant with the same guest and toolchain — plus a shared host
> folder — exists too: [Set up a Windows VMware sandbox](windows-vmware.md).
>
> **What you'll get.** A local sandbox virtual machine: a Windows 11 (ARM64)
> guest with a full coding toolchain and an AI coding agent (OpenCode)
> pre-installed, plus the OpenCodeReview code-review CLI and the OpenChamber
> web UI to run and supervise agent sessions from your host browser — running
> under QEMU on your Apple Silicon Mac. Your code stays on your host; the
> sandbox reaches it through git, the RDP clipboard, or the OpenChamber UI
> (there is no shared host directory — see
> [No shared folder](#no-shared-folder)).
>
> **Quick setup** — three steps and you're done:
>
> 1. [Install QEMU and swtpm](#1-install-qemu-and-swtpm)
> 2. [Run the sandbox](#2-run-the-sandbox)
> 3. [Use the sandbox](#3-use-the-sandbox)
>
> Everything below the **Details** divider is optional reading: what's inside
> the image and how the pieces fit together.

## Quick setup

### Prerequisites

- An Apple Silicon Mac (M1 or newer). Windows on ARM under QEMU requires
  HVF, and HVF can only virtualize ARM64 guests — this sandbox is ARM64-only.
- [QEMU](https://www.qemu.org/) and [swtpm](https://github.com/stefanberger/swtpm)
  (the virtual TPM 2.0 — Windows 11 requires one).
- ~30 GB of free disk space (the image is ~14 GB, the working VM grows on
  top).

### Default account

Every sandbox guest has a single local user, used for SSH and RDP:

| User | Password |
| --- | --- |
| `Administrator` | `sandbox1` |

### 1. Install QEMU and swtpm

```bash
brew install qemu swtpm
```

[`socat`](https://linux.die.net/man/1/socat) is needed for the SSH agent and
Docker bridges (the runner offers to install it when a bridge is needed):

```bash
brew install socat
```

### 2. Run the sandbox

The repo ships a runner script that boots the image, forwards the guest
ports, and wires up the bridges. From the repo root:

```bash
./scripts/run-windows-qemu-sandbox.sh
```

On first use it picks the disk image: the local build output
(`build/windows-arm64-qemu/output/sandbox-windows-11.qcow2`) when
present, otherwise it asks to pull `sandbox-windows-11:latest` from GHCR
via [oras](https://oras.land/) (one-time, ~14 GB — `brew install oras`).
It then
creates a working VM — a copy-on-write overlay plus persistent TPM and EFI
state under `~/Library/Application Support/agent-sandbox/windows-11-arm64-qemu` — the
pristine image is never written to. The guest boots headless or in a QEMU
window (default), and SSH/RDP/OpenChamber ports are forwarded to the host:

| Port | Guest service |
| --- | --- |
| 2222 | SSH |
| 3389 | RDP |
| 4000 | OpenChamber web UI |
| 5985 | WinRM (advanced use) |

When a Docker engine is running on the host (Docker Desktop, Colima,
OrbStack, ...), the runner bridges it into the guest; same for a
password-manager SSH agent (see
[Docker (remote engine)](#docker-remote-engine) and
[SSH agent bridge](#ssh-agent-bridge)). On the very first run the runner
also offers to enable Windows' auto-logon and reboot the guest once — the
image ships with auto-logon disabled after the OOBE boot, and the
OpenChamber web UI only starts at logon (see
[OpenChamber from the host](#openchamber-from-the-host)).

A window opens and the guest logs in automatically. Pass `--foreground` to
keep the terminal attached (Cmd+C stops the VM), `--headless` to run
without a window, `--no-agent` / `--no-docker` to skip a bridge, or
`--reset` to wipe the working VM and start fresh from the pristine image.

> [!NOTE]
> The QEMU window drives the guest resolution directly: the runtime VM
> uses a virtio-gpu-pci display and the image ships the virtio-gpu driver
> (viogpudo), so drag the window edges to resize and Windows changes its
> display resolution to match (no scaling). The QEMU window's **View**
> menu still offers **Enter Fullscreen** (Cmd+F) for native macOS full
> screen and **Zoom To Fit** to toggle the guest-scaling mode.
>
> The working VM is your sandbox: installs, config, and agent state
> accumulate in the COW overlay and survive restarts (like a Tart clone on
> the macOS side). `--reset` deletes the overlay, the TPM state, and the EFI
> NVRAM — everything inside the guest is lost; the pristine image is not
> touched.

### 3. Use the sandbox

Everything is set up now — use it from the host or inside the VM:

- **Browser UI (OpenChamber)**: open `http://127.0.0.1:4000/` on the host
  (default password: `sandbox`) and start or supervise agent sessions — see
  [OpenChamber from the host](#openchamber-from-the-host).
- **Desktop (RDP)**: connect to `127.0.0.1:3389` with Microsoft Remote
  Desktop (or any RDP client), user `Administrator` / `sandbox1`. The guest
  desktop has VS Code, Chrome, Firefox, and a Terminal.
- **Terminal (OpenCode)**: over SSH from the host:

  ```bash
  ssh -p 2222 Administrator@127.0.0.1
  ```

  Then configure the agent's LLM provider once (see
  [Configure the environment](#configure-the-environment)) and start it:

  ```powershell
  opencode
  ```

- **Code review (OpenCodeReview)**: the image ships the `ocr` CLI — see the
  [OpenCodeReview quick start](https://github.com/alibaba/open-code-review#quick-start).

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
  ./scripts/stop-windows-qemu-sandbox.sh
  ```

  This stops qemu (via the `qemu.pid` the runner writes), swtpm and the
  host SSH agent / Docker bridge listeners. The manual fallback is:

  ```bash
  kill $(cat "$HOME/Library/Application Support/agent-sandbox/windows-11-arm64-qemu/qemu.pid")
  ```

  (or `pkill -f qemu-system-aarch64`). Start it again with
  `./scripts/run-windows-qemu-sandbox.sh`.

- **Reset the sandbox** — wipe the working VM and start from the pristine
  image:

  ```bash
  ./scripts/run-windows-qemu-sandbox.sh --reset
  ```

- **Delete the sandbox** — remove the state from the host (the working disk
  overlay, the TPM and EFI NVRAM, and the pulled image cache) and free the
  disk space:

  ```bash
  ./scripts/delete-windows-qemu-sandbox.sh --yes
  ```

  This stops qemu + swtpm first (delegating to `stop-windows-qemu-sandbox.sh`),
  then removes `~/Library/Application Support/agent-sandbox/windows-11-arm64-qemu/`
  (override with `SANDBOX_STATE_DIR`). The next run re-pulls the image and
  starts fresh. Without `--yes` it asks before deleting.

- **Run several sandboxes side by side** — set `SANDBOX_STATE_DIR` to a
  different directory and `SANDBOX_SSH_PORT` / `SANDBOX_RDP_PORT` /
  `SANDBOX_OPENCHAMBER_PORT` to free ports.

---

## Details

### What's in the image

The image is built with [Packer](https://www.packer.io/)'s QEMU plugin from
the official Windows 11 ARM64 ISO (bring-your-own, see
[images/windows-arm64-qemu/README.md](../images/windows-arm64-qemu/README.md))
and runs under `qemu-system-aarch64` with HVF. It ships:

| Component | Detail |
| --- | --- |
| Windows 11 Pro (ARM64) | Unactivated (watermark); generic Pro key used for Setup |
| VirtIO drivers | viostor/vioscsi, NetKVM, vioserial, balloon + qemu guest agent |
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

Verify the toolchain over SSH (`ssh -p 2222 Administrator@127.0.0.1`,
password `sandbox1`):

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
**logon**, listening on `0.0.0.0:4000`; the runner forwards it to the host,
so with the VM running:

```bash
open "http://127.0.0.1:4000"
```

The default UI password is `sandbox`. Notes:

- Because the task fires at logon, the guest must be logged in. The runner
  enables Windows' auto-logon on first use (with your confirmation) so the
  guest logs itself in at boot and the UI comes up without interaction. The
  image's `autounattend.xml` deliberately sets `LogonCount=1` — one OOBE
  auto-login only — which is why the runner re-enables it.
- The UI binds to `0.0.0.0` inside the guest, but QEMU's user-mode network
  only forwards the host ports — nothing is exposed to your LAN.
- `openchamber status` and `openchamber logs` (from the guest) help when
  something is off.

### Docker (remote engine)

The image ships the **Docker CLI** but no local engine: a Windows guest
cannot run a hypervisor (no nested virtualization through HVF), so Docker
Desktop / WSL2 inside the sandbox would fail their hypervisor checks — the
same constraint as the macOS guest. The CLI works as-is against any remote
engine.

**The runner wires the host's engine into the guest automatically.** When a
Docker engine socket is found on the host (Docker Desktop at
`~/.docker/run/docker.sock`, Colima, OrbStack, or `/var/run/docker.sock`),
it bridges it: a host-side `socat` exposes the socket on TCP `4201`
(loopback only), and a guest-side Node relay (served by the image's
`node.exe`) presents it as the `\\.\pipe\docker_engine` named pipe — the
exact pipe Docker on Windows looks for by default. A docker context named
`host` is created and made the default, so `docker`, `docker compose`, and
docker clients that read the default pipe all hit the host engine:

```powershell
# inside the guest — the runner already set up the context
docker context show          # host
docker run --rm hello-world
```

Notes:

- Containers run on the **host engine**, so published ports are bound on
  the host. From inside the guest they are reachable at `10.0.2.2` (QEMU's
  host alias), *not* `localhost`:
  `docker run -d -p 8080:80 nginx` then, in the guest,
  `curl http://10.0.2.2:8080`. From the host itself the port is
  `http://localhost:8080` as usual.
- The bridge survives guest reboots (an ONLOGON scheduled task restarts the
  relays at logon) and the host side reconnects on the next run of the
  runner. The host listener binds to the loopback interface only — the
  engine is not exposed to your LAN.
- The engine must be running when the runner bridges it. If Docker Desktop
  isn't started yet, the runner skips the bridge — start the engine and
  re-run the script (the setup is idempotent).
- Pass `--no-docker` to skip; `SANDBOX_DOCKER_PORT` overrides the bridge
  port (default `4201`; VMware uses `4301`, macOS `4101`, so all three
  sandboxes can run side by side).
- Container-based test frameworks (testcontainers and similar) work out of
  the box: on Windows they dial the default named pipe, which *is* the
  bridged engine.

### SSH agent bridge

The runner also bridges a password-manager SSH agent (Bitwarden, 1Password,
...) into the guest: a host-side `socat` turns the agent socket into TCP
`4200` (loopback only), and a guest-side Node relay serves it as the
`\\.\pipe\openssh-ssh-agent` named pipe. The guest's `SSH_AUTH_SOCK`
environment variable points at that pipe, so `ssh`/`git` inside the guest
authenticate with the host's keys — no keys are copied into the guest.

Notes:

- Only an *overridden* agent is bridged (when `SSH_AUTH_SOCK` points at a
  password manager's socket). The stock macOS launchd agent is not bridged.
- The host listener lives only for the run (it stays up in background mode
  until killed); the guest side persists via the ONLOGON task.
- Pass `--no-agent` to skip; `SANDBOX_AGENT_PORT` overrides the bridge port
  (default `4200`; VMware uses `4300`, macOS `4100`).

### No shared folder

The virtio-fs driver has no ARM64 Windows build (virtio-win issue #1337), so
there is no host-directory mount like the macOS image's shared `dev`
volume. Your code stays on the host; get it into the sandbox with:

- **git** — clone/push from inside the guest (the bridged SSH agent covers
  authentication).
- **RDP clipboard** — copy files and text between host and guest.
- **The OpenChamber web UI** — attach a host directory to a session, or use
  the workspace picker.

### Runner script reference

[`scripts/run-windows-qemu-sandbox.sh`](../scripts/run-windows-qemu-sandbox.sh) is the
automated way to boot, run, and wire up the sandbox. Everything it accepts:

Options:

- `--headless` — run without a window (`-display none`)
- `--foreground` — keep the terminal attached and block until the VM stops
  (Cmd+C stops it). Default is background: the script exits after the
  summary and the VM keeps running
- `--no-agent` — skip the SSH agent bridge setup
- `--no-docker` — skip the Docker engine bridge setup
- `--reset` — delete the working VM state (overlay + TPM + EFI NVRAM) and
  start fresh from the pristine image

Environment variables (defaults in parentheses):

| Variable | Default | What it does |
| --- | --- | --- |
| `WINDOWS_IMAGE` | — | Path to a local `sandbox-windows-11.qcow2` to run instead of the discovered/pulled one |
| `SANDBOX_STATE_DIR` | `~/Library/Application Support/agent-sandbox/windows-11-arm64-qemu` | Working VM state (overlay, TPM, EFI NVRAM) |
| `WINDOWS_PASSWORD` | from the vars file | Administrator password in the guest (override after changing it) |
| `SANDBOX_SSH_PORT` | `2222` | Host port forwarded to guest SSH |
| `SANDBOX_RDP_PORT` | `3389` | Host port forwarded to guest RDP |
| `SANDBOX_WINRM_PORT` | `5985` | Host port forwarded to guest WinRM |
| `SANDBOX_OPENCHAMBER_PORT` | `4000` | Guest port of OpenChamber (host forward) |
| `SANDBOX_AGENT_PORT` | `4200` | TCP port for the SSH agent bridge |
| `SANDBOX_DOCKER_PORT` | `4201` | TCP port for the Docker engine bridge |
| `SANDBOX_CPU_COUNT` | from the vars file | CPUs for the VM |
| `SANDBOX_MEMORY_MB` | from the vars file | RAM for the VM, in MB |
| `GHCR_OWNER` | from the git remote | GHCR owner used when pulling the image |
| `NO_COLOR` | unset | Any non-empty value disables colored output |

## Building your own images

This repository is also a collection of image recipes. See
[DEVELOPMENT.md](../DEVELOPMENT.md) for how to build the Windows image
locally (the ISO is bring-your-own) and publish it to GHCR.
