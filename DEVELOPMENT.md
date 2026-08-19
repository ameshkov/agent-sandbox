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

The running side of a recipe (how to run the VM, share directories, clipboard,
etc.) lives in the per-OS user guides under [docs/](docs/) — keep them in sync
whenever you change how an image behaves.

## Repository layout

```text
├── README.md                      # Index: point of entry to all docs
├── DEVELOPMENT.md                # This document
├── scripts/                       # Shared build, deploy & tag scripts (repo root)
│   ├── build.sh                   # ./scripts/build.sh [<image>]  — packer init + build
│   ├── deploy.sh                  # ./scripts/deploy.sh [<image>] — push to GHCR
│   ├── tag.sh                     # ./scripts/tag.sh [<image>]    — create & push the release git tag
│   └── run-macos-sandbox.sh       # user-facing: pull/run a VM + SSH agent bridge + OpenChamber
├── docs/                          # User-facing, per host OS setup guides
│   ├── macos.md                   # macOS (Apple Silicon) — pull & run, details
│   ├── linux.md                   # placeholder (not supported yet)
│   ├── windows.md                 # placeholder (not supported yet)
│   └── ssh-agent.md               # share the host's SSH agent with the guest
└── images/
    └── mac/                       # macOS guest images (host: Apple Silicon Mac)
        ├── sandbox.pkr.hcl        # Packer template for all macOS images
        ├── README.md              # Image list, build/publish commands
        ├── CHANGELOG.md           # Per-version changelog of the images
        └── vars/                  # One .pkrvars.hcl per image (macOS version)
            └── sandbox-macos-tahoe.pkrvars.hcl
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
     sharing, see [docs/ssh-agent.md](docs/ssh-agent.md)); unversioned
     `python`/`pip` aliases;
   - Visual Studio Code (latest stable, from
     `update.code.visualstudio.com`) with the `code` CLI on PATH;
   - Google Chrome and Mozilla Firefox (latest stable universal macOS
     builds, via Homebrew casks; quarantine is stripped with `xattr` so they
     launch without Gatekeeper prompts);
   - OpenCode (`brew install anomalyco/tap/opencode`);
   - OpenChamber (`npm install -g @openchamber/web`) — web UI for OpenCode;
     installed as a login service (LaunchAgent) listening on `0.0.0.0:3000`,
     reachable from the host at `http://<vm-ip>:3000` (see
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
- On macOS 15+ hosts the "Local Network" permission pop-up may interrupt the
  build — see the workaround in [docs/macos.md](docs/macos.md)
  (Troubleshooting).

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
|----------|------|---------|-------------|
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
| `openchamber_ui_password` | string | `sandbox` | Password protecting the OpenChamber web UI; required because the server binds to `0.0.0.0` (host access: `http://<vm-ip>:3000`, see [docs/macos.md](docs/macos.md)) |
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

## Adding a new platform

To add a new host/guest combination (e.g. macOS host → Linux guest), create a
new `images/<platform>/` directory following the macOS pattern:

1. Packer template with the appropriate builder (e.g. QEMU, or the
   [qocker](https://github.com/AdGuardSoftwareLimited/qocker) Vmfile approach
   for layered Linux images).
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
