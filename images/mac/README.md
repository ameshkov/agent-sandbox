# macOS Sandbox Images

macOS VM images for agent sandboxes, built with [Tart](https://tart.run/) and
[Packer](https://www.packer.io/).

See [docs/macos.md](../../docs/macos.md) for how to pull and run these images,
and [DEVELOPMENT.md](../../DEVELOPMENT.md) for how to build and publish them.

## Available images

Each image is a single macOS version; the image name is fixed per version
(`sandbox-macos-<macos-version>`) and does not include the Xcode version:

| Image | macOS |
|-------|-------|
| `sandbox-macos-tahoe` | 26 (Tahoe) |

## Versioning

Images are published with semantic version tags (`:1.0.0`, `:latest`). The
current version lives in the image's vars file (`image_version`); every release
bumps it, adds a [CHANGELOG.md](CHANGELOG.md) entry, and tags the release
commit `mac-v<version>` (e.g. `mac-v1.2.0`, created with
`./scripts/tag.sh <image>`).

## Building locally

Prerequisites: macOS host with Apple Silicon, [Tart](https://tart.run/),
[Packer](https://www.packer.io/) (`brew install hashicorp/tap/packer`).
The Tart Packer plugin is installed automatically by `packer init`.

```bash
# Run from the repository root

./scripts/build.sh <image-name>

# Example:
./scripts/build.sh sandbox-macos-tahoe

# Or build every image:
./scripts/build.sh
```

The first build pulls the ~50 GB base image
(`ghcr.io/cirruslabs/macos-tahoe-xcode:26.4.1`) and takes a while.
Note that the builder fails if a VM with the same name already exists —
remove it first with `tart delete <image-name>`.

## Publishing

Images are published to GHCR under
`ghcr.io/<owner>/agent-sandbox/macos/<image>:<version>` — build locally with
`./scripts/build.sh`, then push with `./scripts/deploy.sh`. The version tag is
the image's `image_version` from its vars file:

```bash
# One-time: authenticate against GHCR with a token that has `packages:write`
tart login ghcr.io

./scripts/deploy.sh sandbox-macos-tahoe
```
