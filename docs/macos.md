# Set up a macOS sandbox (Apple Silicon)

> **What you'll get.** A local sandbox virtual machine: a macOS guest with a
> full coding toolchain and an AI coding agent (OpenCode) pre-installed, plus
> the OpenChamber web UI to run and supervise agent sessions from your host
> browser, running on your Apple Silicon Mac. Your code stays on your host —
> you share a working directory into the VM and run the agent on it from
> inside the sandbox.
>
> **Quick setup** — four steps and you're done:
>
> 1. [Install Tart](#1-install-tart)
> 2. [Run the sandbox](#2-run-the-sandbox)
> 3. [Configure the environment](#3-configure-the-environment)
> 4. [Use the sandbox](#4-use-the-sandbox)
>
> Everything below the **Details** divider is optional reading: what's inside
> the image and how to configure the VM.

## Quick setup

**Prerequisites**

- An Apple Silicon Mac (M1 or newer). macOS guests cannot run on Intel Macs.
- macOS 13 (Ventura) or newer on the host.
- ~150 GB of free disk space (the image is large).

**Default account**

Every sandbox VM has a single local user. The image auto-logs in as this user
on boot, and the same credentials are used for SSH and Screen Sharing:

| User | Password |
|------|----------|
| `admin` | `admin` |

### 1. Install Tart

[Tart](https://tart.run/) is the virtual machine manager this sandbox runs on.
It is built on Apple's Virtualization framework. Install it with Homebrew:

```bash
brew install cirruslabs/cli/tart
```

### 2. Run the sandbox

The repo ships a runner script that replaces the manual pull, clone, configure,
and run steps. From the repo root:

```bash
./scripts/run-macos-sandbox.sh
```

On first use it asks before pulling the image (~50 GB, one-time) and before
cloning a working VM from it, then applies the recommended settings (8 CPUs /
16 GB RAM, 1280x800 display-refit). It then starts the VM with `--no-audio`
(audio-isolated from the host) and your work directory shared, bridges a
password manager's SSH agent into the guest when one is detected on the host
(see [docs/ssh-agent.md](ssh-agent.md)), offers to copy your host's user
settings — opencode config and credentials, SSH and Git dotfiles — into the
guest once per VM (see [User settings on the
guest](#user-settings-on-the-guest)), restarts OpenChamber so a fresh copy
takes effect, and finishes by verifying OpenChamber and offering to open it in
your browser. The VM runs in the **background** by default: after the summary
the script exits and the VM keeps running (stop it later with `tart stop
sandbox-macos`; tart's output goes to
`~/Library/Logs/agent-sandbox/tart-sandbox-macos.log`). When the VM is
already running, the script asks whether to restart it or keep it running.

A window with the guest desktop opens and auto-logs in as `admin` (password:
`admin`); clipboard sharing works out of the box. Pass `--foreground` to keep
the terminal attached instead — the script then blocks until the VM stops,
and Cmd+C in that terminal stops it too. Pass `--headless` to run without a
window, `--no-agent` to skip the SSH agent bridge, or `--no-settings` to skip
the user settings copy.

To use the sandbox in fullscreen with a proper (sharp, full-window)
resolution, set the guest display to its default first: in the guest open
**System Settings → Displays → Advanced…** and select **Default for display**
— see [Display setup](#display-setup).

This follows the recommended **one VM, many projects** workflow: keep **one**
sandbox VM and share your whole working directory into it, so your code stays
on the host while the toolchain and agent live in the VM and are reused across
all projects (see [The one-VM, many-projects workflow in depth](#the-one-vm-many-projects-workflow-in-depth)).
By default the script shares `/Volumes/dev` — the host directory with all your
projects — into the guest at `/Volumes/My Shared Files/dev`.

Two environment variables cover most needs (the full list is in [Runner script
reference](#runner-script-reference)):

| Variable | Default | What it does |
|----------|---------|--------------|
| `SANDBOX_WORK_DIR` | `/Volumes/dev` | Host directory shared into the guest; empty disables the mount |
| `SANDBOX_VM` | `sandbox-macos` | Name of the working VM — set it to run several sandboxes side by side |

For example, a separate sandbox for one project:

```bash
SANDBOX_VM=my-project SANDBOX_WORK_DIR="$HOME/dev/my-project" ./scripts/run-macos-sandbox.sh
```

### 3. Configure the environment

The coding agent (OpenCode) needs an LLM provider before it can work. In the
VM's Terminal, add yours:

```bash
opencode providers login
```

(In a headless VM, run it over SSH or with `tart exec -t <vm-name> opencode
providers login`.)

This walks you through the provider setup (API key, model, ...). Once
configured, restart OpenChamber so it picks up the provider:

```bash
openchamber restart
```

### 4. Use the sandbox

Everything is set up now — two ways to use it:

- **Browser UI (OpenChamber)**: on the host, open `http://<sandbox-ip>:3000/`
  (the IP is `tart ip <vm-name>`; default password: `sandbox`) and start or
  supervise agent sessions from your browser — see
  [OpenChamber from the host](#openchamber-from-the-host).
- **Terminal (OpenCode)**: in the VM's Terminal, open the shared work
  directory and start the agent:

```bash
cd "/Volumes/My Shared Files/dev"
opencode
```

All your host projects are inside — `cd` into whichever folder you're working
on and the agent sees your code. That's it — you are running an AI coding agent
in an isolated sandbox, with your code safely on the host.

---

## Details

### What's in the image

The images are built with [Packer](https://www.packer.io/) + the
[Tart Packer plugin](https://github.com/cirruslabs/packer-plugin-tart) and run
with Tart. The default image ships the following software:

| Software | Version (default image) |
|----------|-------------------------|
| macOS | 26 (Tahoe) |
| Xcode | 26.4.1 (+ Command Line Tools) |
| Homebrew | latest |
| Node.js + npm | 26 (via nvm) |
| nvm | latest (Node.js version manager) |
| Python | 3.14 (`python`, `python3`, `pip`, `pip3` aliases) |
| Ruby | latest (brew) |
| Visual Studio Code | latest (+ `code` CLI) |
| Google Chrome | latest (universal) |
| Firefox | latest (universal) |
| OpenCode | latest (AI coding agent) |
| OpenChamber | latest (web UI for OpenCode, auto-started on port 3000) |
| CLI tools | `git`, `gh`, `jq`, `ripgrep`, `coreutils`, `curl`, `wget`, `socat`, `bash` |

Verify the toolchain from the guest Terminal (or over SSH:
`ssh admin@$(tart ip <vm-name>)`, password `admin`):

```bash
xcodebuild -version
brew --version
node --version && npm --version
nvm --version
python3 --version
ruby --version
code --version
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version
"/Applications/Firefox.app/Contents/MacOS/firefox" --version
opencode --version
openchamber --version
```

### OpenChamber from the host

[OpenChamber](https://openchamber.dev) is the web UI for OpenCode: start
sessions, supervise them, review changes — all from your host browser. It is
installed in the image and starts automatically at login (LaunchAgent
`dev.openchamber.web`), listening on `0.0.0.0:3000` inside the VM. With the VM
running, open it from the host:

```bash
open "http://$(tart ip <vm-name>):3000"
```

The default UI password is `sandbox` — the same convention as the `admin`
account. To change it, run inside the guest:

```bash
openchamber startup disable
OPENCODE_BINARY="$(command -v opencode)" openchamber startup enable --port 3000 --lan --ui-password 'your-password'
```

(`startup enable` snapshots the current environment into the LaunchAgent, so
keep the `OPENCODE_BINARY` pin from the image when re-enabling the service.)

Notes:

- The VM sits behind Tart's NAT network, so in practice only the host can
  reach the UI — still, don't set an easy password if your host is on a shared
  network.
- The service runs the installed `opencode` CLI under the hood; the image
  bakes the resolved binary path (`OPENCODE_BINARY`) into the LaunchAgent, so
  the service doesn't depend on the login session's `PATH`. `openchamber
  status` (state of the server) and `openchamber logs` (recent output) from
  the guest help when something is off.
- Headless (`tart run --no-graphics`) works too — auto-login still brings up
  the session that hosts the LaunchAgent.

### The one-VM, many-projects workflow in depth

A sandbox VM accumulates useful state (installed tools, agent config, shell
history) — treat that as a feature: keep **one** sandbox VM and mount every
project into it.

Notes:

- Share your whole work volume once (`--dir=dev:/Volumes/dev`) or repeat
  `--dir` per project — in both cases the mount has to be passed on every
  `tart run`. Save the command as a shell alias or a `run-sandbox.sh` script.
- If a project genuinely needs isolation (e.g. an incompatible toolchain),
  clone an extra VM for it — `tart clone sandbox project-a-isolated` — no
  rebuild needed.
- If the sandbox gets messy: `tart stop sandbox && tart delete sandbox`, then
  re-clone from the pristine image. All your code stays safe on the host.

### User settings on the guest

On first run — and again whenever the settings change — the runner offers to
copy your host's user settings into the guest, so the agent works with your
credentials and preferences out of the box. What it copies:

| Source (host) | Destination (guest) | Why |
|---|---|---|
| `~/.config/opencode/opencode.json` (or `.jsonc`) | same path | OpenCode configuration (models, agents, permissions, ...) |
| `~/.local/share/opencode/auth.json` | same path | OpenCode provider credentials — no `opencode auth login` needed in the guest |
| `~/.ssh/allowed_signers` | same path | SSH signing verification |
| `~/.ssh/known_hosts` | same path | SSH host keys you already trust |
| `~/.ssh/*.sh` | same path | SSH helper scripts (e.g. for signing) |
| `~/.gitconfig` | same path | Git identity, aliases, signing config |

The step runs **once per VM**: after copying, a versioned marker file inside
the guest (`~/.config/agent-sandbox/settings-copied`) records the settings
version that was copied, and later runs skip the step. When new settings are
added to the script (and its `settings_version` is bumped), the step runs
again and copies the additional files. Each time it runs it asks for
confirmation and lists what it will copy. To force a re-copy, delete the
marker and re-run:

```bash
tart exec sandbox rm ~/.config/agent-sandbox/settings-copied
./scripts/run-macos-sandbox.sh
```

Notes:

- Only files that exist on the host are copied.
- After a copy, OpenChamber is restarted automatically (`openchamber restart`
  inside the guest) so it picks up the new opencode config and credentials —
  it wraps the opencode CLI and keeps the settings it started with otherwise.
- SSH **keys are not copied** — authentication goes through the bridged SSH
  agent (see [docs/ssh-agent.md](ssh-agent.md)).
- The guest's `~/.ssh/config` is not touched here — it is managed by the SSH
  agent bridge setup (`IdentityAgent`), see [docs/ssh-agent.md](ssh-agent.md).
- Pass `--no-settings` to skip the step for a run.

### Display setup

- The resolution is set with `tart set <vm-name> --display <WxH>` (VM stopped).
  Sizes are in **points (pt)** for macOS guests — a `1920x1080` display is
  *larger* than most laptop screens, and the Tart window can't shrink below the
  configured resolution, which breaks fullscreen. Start small (e.g. `1280x800`)
  and let the display grow with the window.
- `--display-refit` enables automatic display reconfiguration: the guest
  resolution follows the window size, so a fullscreen window fills the screen
  and stays sharp. It requires a **macOS 14+ host**. On macOS 13 hosts it does
  nothing — the fixed resolution is just scaled to the window, and you get
  black bars in fullscreen unless the display size matches your screen's aspect
  ratio.
- Enter fullscreen with **View → Enter Full Screen** (or **⌃⌘F** / the green
  button). If the display doesn't resize on its own, fix it from inside the
  guest: open **System Settings → Displays**, click **Advanced…** (bottom of
  the pane), and under "Display resolution" select **Default for display**
  (the default setting). That kicks the auto-resize in — fullscreen then fills
  the whole screen with a sharp, correct resolution instead of a scaled-up or
  blurry picture.

### Runner script reference

[`scripts/run-macos-sandbox.sh`](../scripts/run-macos-sandbox.sh) is the
automated way to pull, run, and wire up the sandbox. Everything it accepts:

Options:

- `--headless` — run without a window (`tart run --no-graphics`)
- `--foreground` — keep the terminal attached and block until the VM stops
  (Cmd+C in the terminal stops it). Default is background: the script exits
  after the summary and the VM keeps running (`tart stop <vm>` to stop it,
  tart output in `~/Library/Logs/agent-sandbox/tart-<vm>.log`)
- `--no-agent` — skip the SSH agent bridge setup
- `--no-settings` — skip copying the host's user settings into the guest

Environment variables (defaults in parentheses):

| Variable | Default | What it does |
|----------|---------|--------------|
| `SANDBOX_IMAGE` | `sandbox-macos-tahoe` | Pristine image VM to pull and clone from |
| `SANDBOX_VM` | `sandbox-macos` | Name of the working VM |
| `SANDBOX_WORK_DIR` | `/Volumes/dev` | Host directory shared into the guest; empty disables the mount |
| `SANDBOX_MOUNT_NAME` | `dev` | Mount name inside the guest (appears at `/Volumes/My Shared Files/<name>`) |
| `SANDBOX_AGENT_PORT` | `4100` | TCP port for the SSH agent bridge |
| `SANDBOX_OPENCHAMBER_PORT` | `3000` | Guest port of OpenChamber |
| `SANDBOX_CPU_COUNT` | `8` | CPUs for a freshly cloned VM |
| `SANDBOX_MEMORY_MB` | `16384` | RAM for a freshly cloned VM, in MB |
| `GHCR_OWNER` | from the git remote | GHCR owner used when pulling the image |
| `NO_COLOR` | unset | Any non-empty value disables colored output |

## Building your own images

This repository is also a collection of image recipes. See
[DEVELOPMENT.md](../DEVELOPMENT.md) for how to build images locally, add new
images (macOS versions), and publish them to GHCR.
