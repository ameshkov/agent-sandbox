# AGENTS.md

Sandbox VM image recipes for AI coding agents: Packer templates (Tart) that
build a macOS VM with a full coding toolchain, plus user docs. There is no app
code, no tests, no CI — the deliverable is the Packer config, the vars files,
and the docs. Read [DEVELOPMENT.md](DEVELOPMENT.md) before touching image
recipes; it is the authoritative build/release guide.

## Layout

- `images/mac/sandbox.pkr.hcl` — the only Packer template; source is the
  `tart-cli` builder (Cirrus Labs base images from GHCR, `tart-cli` clones a
  `ghcr.io/cirruslabs/macos-<version>-xcode:<tag>` base).
- `images/mac/vars/<image>.pkrvars.hcl` — one vars file per image (per macOS
  version): OS/toolchain versions, VM resources, `image_version`. Single
  source of truth for versions — wire changes through template variables,
  never hardcode in the template.
- `scripts/build.sh`, `scripts/deploy.sh`, `scripts/tag.sh` — wrappers that
  discover images from `images/*/vars/*.pkrvars.hcl`; they resolve the repo
  root themselves, so run them from anywhere.
- `scripts/run-macos-sandbox.sh` — user-facing runner: pulls/clones the sandbox
  if needed, runs it with the recommended settings, bridges the host's SSH
  agent into the guest (see `docs/ssh-agent.md`), and verifies OpenChamber.
- `docs/` — user guides. Only `macos.md` and `ssh-agent.md` are real;
  `linux.md` / `windows.md` are placeholders (only macOS host → macOS guest is
  supported today).
- `images/mac/CHANGELOG.md` — per-image changelog, keep in sync with
  `image_version`; always keeps an `[Unreleased]` section on top and links to
  the release tags (`mac-v<version>`) at the bottom.

## Commands

- Build one image: `./scripts/build.sh sandbox-macos-tahoe` (all images if no
  arg). Fails if a VM with that name already exists — `tart delete
  sandbox-macos-tahoe` first.
- Fast HCL check without a build (from `images/mac/`):
  `packer validate -var-file=vars/<image>.pkrvars.hcl sandbox.pkr.hcl`.
- Publish: `./scripts/deploy.sh <image>` — pushes `<version>` + `:latest` to
  `ghcr.io/<owner>/agent-sandbox/macos/<image>`; needs a one-time
  `tart login ghcr.io` with `packages:write`. Owner comes from the git remote,
  override with `GHCR_OWNER`.
- Tag a release: `./scripts/tag.sh <image>` — creates and pushes the annotated
  git tag `<platform>-v<version>` (e.g. `mac-v1.2.0`); fails on a dirty tree
  or a missing `[<tag>]` CHANGELOG entry. Run after committing a release,
  before `build.sh` + `deploy.sh`.

## Conventions & gotchas

- Image name = vars file name = VM name = `sandbox-macos-<macos-version>`.
  The Xcode version is **not** part of the name (it only selects the base
  image). Never introduce a separate naming scheme.
- Every release: bump `image_version` in the vars file, add a CHANGELOG entry,
  commit, create the release tag (`./scripts/tag.sh <image>`, e.g.
  `mac-v1.2.0`), then `build.sh` + `deploy.sh`. Keep them in sync.
- Any change to an image — the Packer template, its vars file, or the
  provisioner scripts — must be recorded in `images/mac/CHANGELOG.md`, not
  just released versions. Update the changelog in the same change as the
  image itself; never land an image change without a corresponding entry.
- Build prerequisites: Apple Silicon host (Tart VMs can't run on Intel), Tart
  + Packer via Homebrew, ~150 GB free disk; the first build pulls the ~50 GB
  base image. `PACKER_LOG=1` for verbose output. On macOS 15+ hosts the
  "Local Network" permission popup can interrupt builds (workaround in
  `docs/macos.md` Troubleshooting).
- SSH provisioning credentials are fixed by the Cirrus base images:
  `admin`/`admin`.
- `scripts/deploy.sh` maps the `images/` platform dir to the GHCR path
  (`mac` → `macos`) in `registry_platform()` — extend that map when a new
  platform lands, and mirror the `mac` layout (template + `vars/` + README +
  CHANGELOG).
- Docs are part of the deliverable and must stay in sync with the template:
  the "What's in the image" table in `docs/macos.md`, the layout tree in
  `DEVELOPMENT.md`, and `images/mac/README.md` all describe the image — change
  them together.
- There is no automated verification: the only end-to-end check is a full
  image build (~1 hr). Use `packer validate` and review the provisioner shell
  scripts (`set -e -x` inline blocks) carefully before running a build.
