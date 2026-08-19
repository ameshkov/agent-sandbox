packer {
  required_plugins {
    tart = {
      version = ">= 1.20.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# ===== Variables =====
#
# Each sandbox image is a single macOS version, described by a variables file
# in vars/ named after the image (`sandbox-macos-<macos-version>`).  See
# DEVELOPMENT.md for how to add a new macOS version.

variable "macos_version" {
  type = string
}

variable "xcode_version" {
  type = string
}

variable "disk_size" {
  type    = number
  default = 160
  # VM disk size in GB. Must be >= the Cirrus base image disk (140 GB): tart
  # can only grow a disk, never shrink it.
}

variable "cpu_count" {
  type    = number
  default = 4
  # CPU count of the VM.
}

variable "memory_gb" {
  type    = number
  default = 8
  # RAM of the VM in GB.
}

variable "ssh_username" {
  type    = string
  default = "admin"
  # SSH user used for provisioning (fixed in the Cirrus Labs base images).
}

variable "ssh_password" {
  type    = string
  default = "admin"
  # SSH password used for provisioning (fixed in the Cirrus Labs base images).
}

variable "openchamber_ui_password" {
  type    = string
  default = "sandbox"
  # Password protecting the OpenChamber web UI. OpenChamber refuses to bind
  # the server to a network interface without a UI password; the sandbox
  # listens on 0.0.0.0:3000 so the host can reach it (see docs/macos.md).
}

variable "image_version" {
  type = string
  # Semantic version this image is published under; bump it and add a
  # CHANGELOG.md entry for every release.
}

variable "node_version" {
  type = string
  # Node.js version installed via nvm and set as the default (see the
  # "Node.js via nvm" provisioner below).
}

variable "python_version" {
  type = string
  # Homebrew Python version, e.g. "3.14"; also used for the unversioned
  # python/python3/pip/pip3 aliases.
}

variable "brew_formulas" {
  type = list(string)
  default = [
    # Core CLI tools
    "bash", "git", "gh", "jq", "ripgrep", "coreutils", "curl", "wget",
    # SSH agent bridging (docs/ssh-agent.md)
    "socat",
    # Node.js version manager (Keg-only; the Node runtime itself is installed
    # via nvm — see the "Node.js via nvm" provisioner below)
    "nvm",
    # The required programming languages (Python is installed separately by
    # the toolchain provisioner, pinned via python_version)
    "ruby",
    # Docker CLI + plugins (client only — the sandbox is a macOS VM and cannot
    # run a local container engine, see docs/macos.md "Docker (remote engine)";
    # the compose/buildx plugins are wired up in the provisioner below)
    "docker", "docker-compose", "docker-buildx",
  ]
}

variable "extra_brew_formulas" {
  type    = list(string)
  default = []
}

# ===== Builder =====
#
# Derives the sandbox VM from Cirrus Labs' pre-built macOS image with Xcode.
# The base images are published to GHCR, see:
# https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos-
#
# The resulting VM boots to a desktop with auto-login enabled and can be used
# both with graphics (tart run) and headless (tart run --no-graphics).
#
# Audio pass-through to the host (guest sound to host speakers, host
# microphone to the guest) is a per-run Tart flag, not a persisted VM
# setting — the sandbox stays audio-isolated from the host by running with
# `tart run --no-audio` (see docs/macos.md). The build honors the same
# policy via run_extra_args.

source "tart-cli" "tart" {
  vm_base_name = "ghcr.io/cirruslabs/macos-${var.macos_version}-xcode:${var.xcode_version}"
  # The image name is fixed per macOS version: sandbox-macos-<macos-version>.
  # The Xcode version selects the base image only and is not part of the name.
  vm_name      = "sandbox-macos-${var.macos_version}"
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size
  headless     = true
  ssh_password = var.ssh_password
  ssh_username = var.ssh_username
  ssh_timeout  = "120s"
  # No audio pass-through with the host during the build either (Tart attaches
  # the VirtIO sound device even when running headless).
  run_extra_args = ["--no-audio"]
}

# ===== Provisioners =====

build {
  sources = ["source.tart-cli.tart"]

  # Base system setup: Xcode license, SSH + Screen Sharing (for tart run --vnc),
  # auto-login as admin (boots straight into the desktop and creates an
  # unlocked login.keychain, which is required for headless VMs on macOS 15+).
  provisioner "shell" {
    inline = [<<-END
set -e -x
# Xcode (already pre-installed in the Cirrus Labs base image)
sudo xcodebuild -license accept || true
sudo xcode-select -p || true

# Remote Login (SSH) and Screen Sharing (VNC) — used by `tart run --vnc`
# and by `tart ip`-based SSH from the host.
sudo systemsetup -setremotelogin on || true
sudo launchctl enable system/com.apple.screensharing || true
sudo launchctl kickstart -k system/com.apple.screensharing || true

# Auto-login as admin: boot lands straight on the desktop.
sudo sysadminctl -autologin set -userName admin -password admin || true

# Friendly hostname for the VM
sudo scutil --set ComputerName "Agent Sandbox" || true
sudo scutil --set HostName "agent-sandbox" || true
sudo scutil --set LocalHostName "agent-sandbox" || true

# Tart Guest Agent (pre-installed in Cirrus base images) powers clipboard
# sharing in GUI mode and `tart exec`.  Check that it is present.
if pgrep -x tart-guest-agent >/dev/null; then
    echo "tart-guest-agent: OK"
else
    echo "tart-guest-agent: MISSING" >&2
fi
END
    ]
  }

  # Homebrew toolchain: nvm (Node version manager), python, ruby and CLI
  # utilities.  Node.js itself is installed via nvm in the provisioner below.
  provisioner "shell" {
    inline = [<<-END
set -e -x
touch ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

brew update
brew install python@${var.python_version}
brew install ${join(" ", concat(var.brew_formulas, var.extra_brew_formulas))}

# Make Homebrew available to non-interactive shells
grep -qxF 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile || \
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile

# Unversioned python/pip aliases pointing at brew's python@${var.python_version}
sudo ln -sf /opt/homebrew/bin/python${var.python_version} /opt/homebrew/bin/python3
sudo ln -sf /opt/homebrew/bin/python${var.python_version} /opt/homebrew/bin/python
sudo ln -sf /opt/homebrew/bin/pip${var.python_version} /opt/homebrew/bin/pip3
sudo ln -sf /opt/homebrew/bin/pip${var.python_version} /opt/homebrew/bin/pip

source ~/.zprofile
python3 --version && pip3 --version
ruby --version
END
    ]
  }

  # Node.js via nvm — brew's nvm formula is keg-only, so we wire it into
  # ~/.zprofile and install the node_version from the vars file as the
  # default version for both interactive and non-interactive shells.
  provisioner "shell" {
    inline = [<<-END
set -e -x
# Load nvm in every shell (brew's nvm is keg-only).  nvm use default picks the
# alias created below; the || true keeps non-interactive shells happy before
# the default alias exists.
grep -qxF 'export NVM_DIR="$HOME/.nvm"' ~/.zprofile || \
    cat >> ~/.zprofile <<'NVM'
export NVM_DIR="$HOME/.nvm"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
nvm use default >/dev/null 2>&1 || true
NVM

source ~/.zprofile
nvm install ${var.node_version}
nvm alias default ${var.node_version}

node --version && npm --version
nvm --version
END
    ]
  }

  # Visual Studio Code
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile
curl -fsSL -o /tmp/vscode.zip "https://update.code.visualstudio.com/latest/darwin-universal/stable"
unzip -q /tmp/vscode.zip -d /tmp/vscode
sudo rm -rf "/Applications/Visual Studio Code.app"
sudo mv "/tmp/vscode/Visual Studio Code.app" /Applications/
rm -rf /tmp/vscode /tmp/vscode.zip

# Drop the quarantine attribute so the app launches without Gatekeeper prompts
sudo xattr -dr com.apple.quarantine "/Applications/Visual Studio Code.app" || true

# `code` CLI on PATH
sudo ln -sf "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" /opt/homebrew/bin/code

code --version
END
    ]
  }

  # Browsers — Google Chrome and Mozilla Firefox (latest stable universal
  # macOS builds, via Homebrew casks). Quarantine is stripped explicitly so
  # they launch without Gatekeeper prompts (the VM boots straight to the
  # desktop and may run headless; same choice as the xattr call for VS Code
  # above — brew's own --no-quarantine flag was removed in newer Homebrew).
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile
brew install --cask google-chrome firefox

# Drop the quarantine attribute so the apps launch without Gatekeeper prompts
sudo xattr -dr com.apple.quarantine "/Applications/Google Chrome.app" || true
sudo xattr -dr com.apple.quarantine "/Applications/Firefox.app" || true

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version
"/Applications/Firefox.app/Contents/MacOS/firefox" --version
END
    ]
  }

  # Sublime Text — the text editor (Homebrew cask, current stable build).
  # The cask also links the `subl` CLI into the Homebrew bin dir.
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile
brew install --cask sublime-text

# Drop the quarantine attribute so the app launches without Gatekeeper prompts
sudo xattr -dr com.apple.quarantine "/Applications/Sublime Text.app" || true

"/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl" --version
END
    ]
  }

  # OpenCode — the AI coding agent
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile
# The recommended Homebrew tap, see https://opencode.ai/docs/
brew install anomalyco/tap/opencode
opencode --version
END
    ]
  }

  # OpenChamber — the native macOS desktop app (https://openchamber.dev),
  # installed alongside the web UI below. Distributed as the `openchamber`
  # Homebrew cask (the arm64 build on Apple Silicon); the cask pins the DMG
  # checksum and stays in sync with the GitHub releases. The app bundles its
  # own OpenCode CLI and manages its own server by default — the sandbox's
  # web UI service on port 3000 below remains the main server; docs/macos.md
  # explains how to pair the app with it so both share sessions.
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile
brew install --cask openchamber

# Drop the quarantine attribute so the app launches without Gatekeeper
# prompts (same choice as the browsers above)
sudo xattr -dr com.apple.quarantine "/Applications/OpenChamber.app" || true

test -d "/Applications/OpenChamber.app"
defaults read "/Applications/OpenChamber.app/Contents/Info.plist" CFBundleShortVersionString
END
    ]
  }

  # OpenChamber — web UI for OpenCode (https://openchamber.dev). Installed via
  # npm (requires Node.js 22+, the image ships 26 via nvm, and the opencode
  # CLI on PATH). Registered as a login service (LaunchAgent
  # dev.openchamber.web) that listens on 0.0.0.0:3000, so the host can open
  # the UI at http://$(tart ip <vm>):3000 — see docs/macos.md.
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile
npm install -g @openchamber/web
openchamber --version

# Pin the opencode binary the service will run: `startup enable` snapshots
# the environment into the LaunchAgent, so resolving the absolute path here
# (instead of relying on PATH lookup inside the login session) guarantees
# OpenChamber uses exactly the opencode this image ships.
opencode_bin="$(command -v opencode)"
test -x "$opencode_bin"
export OPENCODE_BINARY="$opencode_bin"
echo "OpenChamber will run opencode at: $OPENCODE_BINARY"

# Auto-start at login, bind to 0.0.0.0 for host access. --lan refuses to
# start without a UI password, hence openchamber_ui_password.
# During image builds the admin user may not have a GUI login session yet
# (auto-login applies on the next boot), so a failed immediate start is OK:
# the plist is installed and RunAtLoad starts the service at first login.
openchamber startup enable --port 3000 --lan --ui-password "${var.openchamber_ui_password}" \
    || echo "WARNING: OpenChamber service installed but not started yet (expected during image builds); it will start at first login"

openchamber startup status

# Health check if the service already came up during the build.
if curl -fsS --max-time 5 http://127.0.0.1:3000/health >/dev/null 2>&1; then
    echo "OpenChamber: OK (http://127.0.0.1:3000/health)"
else
    echo "WARNING: OpenChamber not reachable yet; it will start at first login"
fi
END
    ]
  }

  # Docker CLI — client only. The sandbox is a macOS VM, and Apple's
  # Virtualization.framework does not support nested virtualization for macOS
  # guests (only Linux guests on M3+ with macOS 15+), so no container engine
  # (Docker Desktop, Colima, ...) can run inside it. The CLI is meant to be
  # pointed at a remote engine — e.g. the host's Docker Desktop over SSH; see
  # docs/macos.md "Docker (remote engine)". The brew docker-compose and
  # docker-buildx formulas install the compose/buildx plugins into
  # $HOMEBREW_PREFIX/lib/docker/cli-plugins; the CLI only discovers them via
  # cliPluginsExtraDirs in ~/.docker/config.json.
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile

# Wire Homebrew's cli-plugins dir into the docker CLI config so `docker
# compose` and `docker buildx` are found. docker preserves this key when the
# user later runs `docker context use ...` (the file never pre-exists in a
# fresh image; the jq branch is only defensive).
mkdir -p ~/.docker
if [ -f ~/.docker/config.json ]; then
    jq '.cliPluginsExtraDirs += ["/opt/homebrew/lib/docker/cli-plugins"] | .cliPluginsExtraDirs |= unique' \
        ~/.docker/config.json > /tmp/docker-config.json
    mv /tmp/docker-config.json ~/.docker/config.json
else
    cat > ~/.docker/config.json <<'DOCKER'
{
  "cliPluginsExtraDirs": [
    "/opt/homebrew/lib/docker/cli-plugins"
  ]
}
DOCKER
fi

docker --version
docker compose version
docker buildx version
END
    ]
  }

  # Final verification and cleanup
  provisioner "shell" {
    inline = [<<-END
set -e -x
source ~/.zprofile
brew cleanup

echo "===== Agent Sandbox image contents ====="
sw_vers
xcodebuild -version
brew --version | head -1
node --version
npm --version
nvm --version
python3 --version
pip3 --version
ruby --version
git --version
gh --version | head -1
code --version | head -1
subl --version
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version
"/Applications/Firefox.app/Contents/MacOS/firefox" --version
opencode --version
openchamber --version
defaults read "/Applications/OpenChamber.app/Contents/Info.plist" CFBundleShortVersionString
docker --version
docker compose version
docker buildx version
echo "========================================"
END
    ]
  }
}
