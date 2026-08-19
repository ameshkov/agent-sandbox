# Set up a macOS sandbox (Apple Silicon)

> **What you'll get.** A local sandbox virtual machine: a macOS guest with a
> full coding toolchain and an AI coding agent (OpenCode) pre-installed, plus
> the OpenChamber web UI to run and supervise agent sessions from your host
> browser, running on your Apple Silicon Mac. Your code stays on your host —
> you share a working directory into the VM and run the agent on it from
> inside the sandbox.
>
> **Quick setup** — seven steps and you're done:
>
> 1. [Install Tart](#1-install-tart)
> 2. [Sign in to the image registry](#2-sign-in-to-the-image-registry) *(one-time)*
> 3. [Pull the image](#3-pull-the-image)
> 4. [Clone a working sandbox](#4-clone-a-working-sandbox)
> 5. [Configure the sandbox (CPU, memory, display)](#5-configure-the-sandbox-cpu-memory-display)
> 6. [Run the sandbox with your working directory shared](#6-run-the-sandbox-with-your-working-directory-shared)
> 7. [Run the coding agent](#7-run-the-coding-agent)
>
> Everything below the **Details** divider is optional reading: what's inside
> the image, how to configure the VM, and troubleshooting.

## Quick setup

**Prerequisites**

- An Apple Silicon Mac (M1 or newer). macOS guests cannot run on Intel Macs.
- macOS 13 (Ventura) or newer on the host.
- ~150 GB of free disk space (the image is large; see
  [Troubleshooting](#troubleshooting)).

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

### 2. Sign in to the image registry

The images are published to GHCR. This repository is private, so authenticate
once with a GitHub token that has `read:packages` scope:

```bash
tart login ghcr.io
```

### 3. Pull the image

Pull the pre-built image. Replace `<owner>` with the GitHub account or
organization that owns this repository:

```bash
tart pull ghcr.io/<owner>/agent-sandbox/macos/sandbox-macos-tahoe:latest
```

Images are versioned with semantic version tags (e.g. `:1.0.0`) plus
`:latest`; `:latest` always points at the most recent build.

### 4. Clone a working sandbox

Never run the pristine image directly — keep it clean. Instead, clone a working
copy. Thanks to copy-on-write this costs almost no extra disk, and you can
re-clone from the pristine image in seconds whenever the sandbox gets messy:

```bash
tart clone sandbox-macos-tahoe sandbox
```

### 5. Configure the sandbox (CPU, memory, display)

Before the first run, give the VM enough resources and a display that fits your
screen — do this once, right after cloning (the VM must be stopped):

```bash
tart set sandbox --cpu 8 --memory 16384
tart set sandbox --display 1280x800 --display-refit
```

- Defaults are 4 CPUs / 8 GB / `1024x768` — bump the CPU/memory if the sandbox
  feels slow.
- Display sizes are in **points** (macOS guests); `--display-refit` makes the
  guest resolution follow the window, so fullscreen resizes and stays sharp.
  Pick a size that fits your screen — see [Display setup](#display-setup) for
  details.

### 6. Run the sandbox with your working directory shared

This follows the recommended **one VM, many projects** workflow: keep **one**
sandbox VM and share your whole working directory into it, so your code stays
on the host while the toolchain and agent live in the VM and are reused across
all projects. Start the VM with your work directory mounted:

```bash
tart run \
    --dir=dev:/Volumes/dev \
    --no-audio \
    sandbox
```

`/Volumes/dev` is the directory with **work-related stuff on the host
machine** — all your projects live there. Inside the VM it appears as a single
shared directory named `dev`.

`--no-audio` keeps the sandbox audio-isolated from the host: the guest gets no
access to the host's microphone and can't play sound on the host's speakers.
Omit it only if you deliberately want to share audio with the host.

A window with the guest desktop opens. Auto-login is configured in the image,
so the VM boots straight into the desktop as user `admin` (password: `admin`);
clipboard sharing works out of the box. The shared directory appears inside the
guest under `/Volumes/My Shared Files/dev`.

### 7. Run the coding agent

In the VM's Terminal, open the shared work directory and start the agent:

```bash
cd "/Volumes/My Shared Files/dev"
opencode
```

All your host projects are inside — `cd` into whichever folder you're working
on and the agent sees your code. That's it — you are running an AI coding agent
in an isolated sandbox, with your code safely on the host.

Prefer a browser UI? OpenChamber is already running on port 3000 — from the
host open `http://$(tart ip sandbox):3000` (default password: `sandbox`; see
[OpenChamber from the host](#openchamber-from-the-host)).

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
| OpenCode | latest (AI coding agent) |
| OpenChamber | latest (web UI for OpenCode, auto-started on port 3000) |
| CLI tools | `git`, `gh`, `jq`, `ripgrep`, `coreutils`, `curl`, `wget`, `socat`, `bash` |

Verify the toolchain from the guest Terminal (or SSH, see below):

```bash
xcodebuild -version
brew --version
node --version && npm --version
nvm --version
python3 --version
ruby --version
code --version
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
openchamber startup enable --port 3000 --lan --ui-password 'your-password'
```

Notes:

- The VM sits behind Tart's NAT network, so in practice only the host can
  reach the UI — still, don't set an easy password if your host is on a shared
  network.
- The service runs the installed `opencode` CLI under the hood; `openchamber
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
  button). If the display doesn't resize on its own, open **System Settings →
  Displays** inside the guest and confirm **Resolution: Default for display** —
  that kicks the auto-resize in.

### Running the VM

**With graphics (default)**

```bash
tart run --no-audio <vm-name>
```

Useful options:

- `tart set <vm-name> --display 1280x800 --display-refit` — set the guest
  resolution (run while the VM is stopped; see
  [Display setup](#display-setup)). Default is `1024x768`.
- `tart set <vm-name> --cpu 8 --memory 16384` — give the VM more resources.
  Defaults are 4 CPUs / 8 GB.
- `tart run --dir=... <vm-name>` — see
  [Sharing the development directory](#sharing-the-development-directory).

**Without graphics (headless)**

```bash
tart run --no-graphics --no-audio <vm-name>
```

The VM runs in the background. Interact with it over SSH:

```bash
ssh admin@$(tart ip <vm-name>)
# password: admin
```

or run single commands (add `-t` for interactive/TUI programs like `opencode`):

```bash
tart exec <vm-name> xcodebuild -version
tart exec -t <vm-name> opencode
```

**With VNC (screen sharing)**

Prefer a graphical session but no Tart window? Screen Sharing supports
copy/paste and drag-and-drop:

```bash
tart run --vnc --no-audio <vm-name>
```

Then connect from the host with Screen Sharing (Finder → Go → Connect to
Server → `vnc://<ip>`), where `<ip>` is `tart ip <vm-name>`. Screen Sharing is
already enabled inside the image.

### Audio

The sandbox runs with **no audio sharing** with the host (`--no-audio`): the
guest can't record from the host's microphone and can't play sound through the
host's speakers. This is on purpose — a sandboxed agent should have no way to
listen to or emit audio on your machine. Run the VM with `--no-audio` on every
start (all three modes above already include it; save the command in a shell
alias or a `run-sandbox.sh` script, see
[Sharing the development directory](#sharing-the-development-directory)). If
you ever need audio in the VM, just drop the flag.

### Sharing the development directory

Mount a host directory into the guest with `--dir`:

```bash
tart run --dir=work:~/dev/my-project <vm-name>
```

In the guest the directory appears at `/Volumes/My Shared Files/work`.

- The first part (`work`) is the mount name, the second is the host path.
- Repeat `--dir` to share several directories.
- Append `:ro` to mount read-only:
  `tart run --dir=work:~/dev/my-project:ro <vm-name>`.
- `--dir` must be passed on every `tart run` invocation — save your run
  command in a shell script or alias.
- Inside the guest the shared directory can be remounted anywhere, e.g.
  `sudo mount_virtiofs com.apple.virtio-fs.automount ~/workspace` (then it
  appears at `~/workspace/work`).

### Sharing the clipboard

- **GUI mode**: clipboard sharing between host and guest is **enabled by
  default** (powered by the Tart Guest Agent, pre-installed in the image).
  Disable it with `tart run --no-clipboard <vm-name>` if you ever need to.
- **VNC / Screen Sharing**: copy/paste works as well.
- **Headless without VNC**: no clipboard; use a shared directory or `tart
  exec` instead.

### Passing files to the VM

1. **Shared directory** (recommended for code): mount with `--dir`, see
   above.
2. **scp over SSH** (one-off files):

   ```bash
   scp ./my-file.txt admin@$(tart ip <vm-name>):
   # password: admin
   ```

   (in both directions — from the guest, `scp` back to the host works too).
3. **`tart exec` with stdin** (no SSH needed):

   ```bash
   cat ./my-file.txt | tart exec -i <vm-name> sh -c 'cat > my-file.txt'
   ```

4. **Drag and drop** into the VM via Screen Sharing (`tart run --vnc`).

### Sharing the SSH agent

The coding agent often needs SSH access (`git push`, etc.) and your keys may
live in a password manager on the host (Bitwarden, 1Password, KeePassXC, ...).
The agent socket can't cross a directory mount — Unix sockets are kernel
objects, not files — so the guest gets its own socket backed by a bridge to
the host. The full guide is [docs/ssh-agent.md](ssh-agent.md); the short
version (Bitwarden example; the socket path differs per manager):

Host:

```bash
GW=$(tart ip sandbox | awk -F. '{print $1"."$2"."$3".1"}')
socat TCP-LISTEN:4100,reuseaddr,fork,bind="$GW" \
    UNIX-CONNECT:"$HOME/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"
```

Guest:

```bash
HOST_GW=$(netstat -nr | awk '/default/{print $2; exit}')
socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,unlink-early,mode=600 \
    TCP:"$HOST_GW":4100 &
export SSH_AUTH_SOCK=/tmp/ssh-agent.sock   # add to ~/.zprofile
```

`socat` is included in the sandbox image; on the host, install it once with
`brew install socat`.

### Managing VMs

| Task | Command |
|------|---------|
| List VMs | `tart list` |
| Stop a VM | `tart stop <vm-name>` |
| Delete a VM | `tart delete <vm-name>` |
| Rename a VM | `tart rename <vm-name> <new-name>` |
| Clone a VM (CoW, cheap) | `tart clone <source-vm> <new-vm>` |
| Suspend / resume | `tart suspend <vm-name>`, then `tart run <vm-name>` |
| Resize the disk | `tart set <vm-name> --disk-size 160` (see [FAQ](https://tart.run/faq/#disk-resizing) for macOS specifics) |
| Back up a VM | `tart export <vm-name> my-sandbox.tvm`, restore with `tart import my-sandbox.tvm <vm-name>` |

### Troubleshooting

- **The image is huge.** The base macOS image with Xcode is ~50 GB and the
  sandbox VM itself takes another ~80 GB of disk. `tart list` shows what you
  have; `tart prune` removes OCI/IPSW caches.
- **"Local Network" permission pop-up** (macOS 15+ host): Packer or other
  tools connecting to the VM may trigger it. To allow all private address
  ranges once and for all:

  ```bash
  sudo defaults write com.apple.network.local-network AllowedEthernetLocalNetworkAddresses -array "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
  sudo defaults write com.apple.network.local-network AllowedWiFiLocalNetworkAddresses -array "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
  ```

  ...and reboot the host.
- **Headless VM won't start** with errors about `login.keychain` (macOS 15+
  host): our images enable auto-login, which creates an unlocked keychain at
  first boot. If you built your own image without it, log in via the GUI or
  Screen Sharing at least once.
- **Can't find the VM's IP**: make sure the VM is running, then
  `tart ip <vm-name>`.
- **Connecting to host services from the VM**: with the default NAT network
  the host is reachable at the default gateway IP — from inside the guest run
  `netstat -nr | awk '/default/{print $2; exit}'`.
- **The VM feels slow**: check `tart set <vm-name> --cpu`/`--memory`; the
  default image is configured for 4 CPUs / 8 GB.
- **Black bars in fullscreen / display doesn't resize**: on macOS 13 hosts
  automatic display reconfiguration isn't available — set the display size to
  match your screen's aspect ratio (see [Display setup](#display-setup)). On
  macOS 14+ hosts, open **System Settings → Displays** inside the guest and
  select **Resolution: Default for display**.

## Building your own images

This repository is also a collection of image recipes. See
[DEVELOPMENT.md](../DEVELOPMENT.md) for how to build images locally, add new
images (macOS versions), and publish them to GHCR.
