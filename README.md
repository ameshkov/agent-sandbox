# agent-sandbox

Local sandbox virtual machines for AI coding agents. A pre-built image with
the full toolchain (macOS with Xcode/Homebrew, Windows 11 ARM64 with
VS2022/toolchains, or Ubuntu 24.04 with the open-source toolchain; OpenCode,
OpenCodeReview, OpenChamber, Docker CLI bridged to the host) runs on your
Mac. Your code stays on the host — you share a working directory into the VM
and let a coding agent work on it in an isolated sandbox. The
[`agent-dev-env`](https://www.npmjs.com/package/agent-dev-env) CLI builds,
runs, and wires up the sandboxes, and manages their image releases.

**Currently supported:** macOS host on Apple Silicon → macOS (Tart),
Windows 11 ARM64 (QEMU, VMware Fusion) and Ubuntu 24.04 LTS ARM64 (VMware
Fusion) guests. Linux hosts are coming soon.

## Quick start

Try it without installing:

```bash
npx agent-dev-env doctor            # host + tooling check for every platform
npx agent-dev-env run macos         # pull, boot, and wire up the macOS sandbox
```

Or install the CLI globally:

```bash
npm install -g agent-dev-env
agent-dev-env run macos
```

On first use the CLI asks before pulling the image (~50 GB, one-time) and
creating the working VM, then starts it with the recommended settings and
your work directory shared. It also bridges the host's SSH agent and Docker
engine into the guest and copy your user settings in — see the
[macOS guide](docs/macos.md) for the full walkthrough and the
[CLI reference](docs/cli.md) for every command and option.

> Tip: `agent-dev-env doctor` checks Tart/QEMU/Fusion/oras and free disk
> before you start; the per-platform guides list the official install
> commands.

## Guides

Pick the guide for your operating system:

| Operating system | Guide |
| --- | --- |
| macOS (Apple Silicon) | [Set up your macOS sandbox](docs/macos.md) |
| Ubuntu (VMware) | [Set up your Ubuntu sandbox](docs/ubuntu-vmware.md) |
| Windows (QEMU) | [Set up your Windows sandbox](docs/windows-qemu.md) |
| Windows (VMware) | [Set up your Windows VMware sandbox](docs/windows-vmware.md) |

The [macOS guide](docs/macos.md) starts with a short, four-step quick setup
and is all you need to have a sandbox with a coding agent running.

## Documentation

User guides and reference:

- [docs/cli.md](docs/cli.md) — the `agent-dev-env` CLI reference: commands,
  options, environment variables, paths.
- [docs/macos.md](docs/macos.md) — user guide: pull, run, share code, run
  the agent (macOS guest).
- [docs/ubuntu-vmware.md](docs/ubuntu-vmware.md) — Ubuntu 24.04 (ARM64)
  guest under VMware Fusion.
- [docs/windows-qemu.md](docs/windows-qemu.md) — Windows 11 (ARM64) guest
  under QEMU.
- [docs/windows-vmware.md](docs/windows-vmware.md) — Windows 11 (ARM64)
  guest under VMware Fusion.
- [docs/ssh-agent.md](docs/ssh-agent.md) — how the SSH agent bridge shares
  the host's passwords manager (Bitwarden, 1Password, ...) with the
  sandbox.

Image recipes — per-platform build/publish commands:

- [images/mac/README.md](images/mac/README.md) — macOS images.
- [images/windows-arm64-qemu/README.md](images/windows-arm64-qemu/README.md)
  — Windows 11 ARM64 under QEMU.
- [images/windows-arm64-vmware/README.md](images/windows-arm64-vmware/README.md)
  — Windows 11 ARM64 under VMware.
- [images/ubuntu-arm64-vmware/README.md](images/ubuntu-arm64-vmware/README.md)
  — Ubuntu 24.04 ARM64 under VMware.

For maintainers and contributors:

- [AGENTS.md](AGENTS.md) — project map, how to build and use the CLI and
  the images, releases/tags/changelogs, code guidelines.
- [DEVELOPMENT.md](DEVELOPMENT.md) — prerequisites and how to build and
  debug the CLI and the recipes.
- [docs/plan.md](docs/plan.md) — the design document of the CLI port.
- [CHANGELOG.md](CHANGELOG.md) — the repo changelog.
