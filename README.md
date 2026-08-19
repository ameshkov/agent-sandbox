# agent-sandbox

Local sandbox virtual machines for AI coding agents. A pre-built image with the
full toolchain (macOS, Xcode, Homebrew, Node, Python, Ruby, VS Code, OpenCode)
runs on your Mac via [Tart](https://tart.run/). Your code stays on the host —
you share a working directory into the VM and let a coding agent work on it in
an isolated sandbox.

**Currently supported:** macOS host → macOS guest (Apple Silicon).

## Get started

Pick the guide for your operating system:

| Operating system | Guide |
|------------------|-------|
| macOS (Apple Silicon) | [Set up your macOS sandbox](docs/macos.md) |
| Linux | [Coming soon](docs/linux.md) |
| Windows | [Coming soon](docs/windows.md) |

The [macOS guide](docs/macos.md) starts with a short, four-step quick setup and
is all you need to have a sandbox with a coding agent running.

## Documentation

- [docs/macos.md](docs/macos.md) — user guide: pull, run, share code, run the
  agent.
- [docs/ssh-agent.md](docs/ssh-agent.md) — share the host's SSH agent
  (Bitwarden, 1Password, ...) with the sandbox.
- [DEVELOPMENT.md](DEVELOPMENT.md) — for contributors: build the images with
  Packer, add new macOS versions, publish to GHCR.
- [images/mac/README.md](images/mac/README.md) — available images and
  per-platform build/publish commands.
