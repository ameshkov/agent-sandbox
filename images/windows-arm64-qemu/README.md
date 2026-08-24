# Windows Sandbox Images

Windows 11 (ARM64) sandbox VM images built with [Packer](https://www.packer.io/)
and the [QEMU plugin](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu)
on an Apple Silicon Mac. The output is a qcow2 disk image; the macOS host
runs it under `qemu-system-aarch64` with the HVF accelerator (near-native
performance — HVF can only virtualize ARM64 guests, so this image is
ARM64-only).

See [docs/macos.md](../../docs/macos.md) for the macOS images and
[docs/windows-qemu.md](../../docs/windows-qemu.md) for the Windows sandbox user guide
(boot it with [scripts/run-windows-sandbox.sh](../../scripts/run-windows-sandbox.sh)).

## Prerequisites

- Apple Silicon Mac (M-series).
- [QEMU](https://www.qemu.org/): `brew install qemu` (provides
  `qemu-system-aarch64`, `qemu-img`, and the edk2 AAVMF firmware).
- [swtpm](https://github.com/stefanberger/swtpm) for the virtual TPM 2.0
  (Windows 11 system requirement): `brew install swtpm`.
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`
  (the QEMU plugin is installed automatically by `packer init`).
- The **Windows 11 ARM64 ISO** — bring your own, Microsoft does not permit
  redistribution:

  1. Visit [Download Windows 11 (ARM64)](https://www.microsoft.com/software-download/windows11arm64)
     and generate a download link (no Insider login required).
  2. Download the ISO (e.g. `Win11_24H2_English_Arm64.iso`, ~5 GB) and
     copy the SHA256 shown on the page into `iso_sha256` in the vars file.
  3. Set `WINDOWS_ISO_PATH` to its absolute path when building.

- **virtio-win.iso** with ARM64 drivers (release 0.1.240 or later). The
  wrapper downloads it automatically from the URL pinned in the vars file,
  or you can point `VIRTIO_WIN_ISO_PATH` at a local copy.

## How to Build

```bash
# From the repository root
WINDOWS_ISO_PATH=/path/to/Win11_24H2_English_Arm64.iso \
  ./scripts/build.sh sandbox-windows-11
```

`scripts/build.sh` delegates to `images/windows-arm64-qemu/build.sh` when a platform
directory ships its own wrapper. The wrapper:

1. Verifies the host (Apple Silicon), the tools, and the Windows ISO
   (SHA256 against `iso_sha256` from the vars file).
2. Downloads virtio-win.iso into
   `build/windows-arm64-qemu/packer_cache/` unless `VIRTIO_WIN_ISO_PATH`
   is set.
3. Mounts virtio-win.iso and stages the ARM64 `viostor` / `vioscsi` /
   `NetKVM` driver subset into
   `build/windows-arm64-qemu/drivers/staging/`, which Packer packs
   into the same CD as `autounattend.xml` (WinPE drive-letter
   enumeration on ARM64 is non-deterministic, so a separate drivers CD
   would be a guessing game).
4. Starts `swtpm` (TPM 2.0) and runs `packer init` + `packer build`
   with the vars file; Packer's `qemu_binary` points at
   `qemu-with-tpm.sh`, which appends the TPM/ramfb/USB/CD-ROM wiring the
   plugin's `qemuargs` option cannot express.
5. Runs a VNC **build watchdog** (`scripts/watch-build.sh`) alongside
   `packer build`: the headless boot's Enter-spam can hit "Cancel" on
   Windows Setup's "Installing Windows 11" screen, and boot races can land
   in the UEFI shell — the watchdog OCRs the VNC framebuffer (Apple
   Vision, pinned VNC port 5901) and auto-dismisses the dialog, answers
   the "Press any key" prompt, or boots the ISO from the shell. Needs
   `pip3 install vncdotool`; skipped with a warning when missing.
6. Compresses the resulting qcow2 with zstd.

A build takes roughly 30 minutes on an M-series Mac (Windows Setup itself
dominates; HVF runs the guest at near-native speed). Everything per image
lives in a top-level `build/` directory (gitignored):
`build/windows-arm64-<platform>/output/`
(`sandbox-windows-11.qcow2`, compressed with zstd), plus `packer_cache/`
and `drivers/staging/`. The macOS/tart images build no files and have no
such directory.

## What's in the image

| Component | Detail |
| --- | --- |
| Windows 11 Pro (ARM64) | Unactivated (watermark); generic Pro key used for Setup |
| VirtIO drivers | viostor/vioscsi, NetKVM, vioserial, balloon + qemu guest agent (from virtio-win guest tools) |
| Chocolatey | Community package manager (versions pinned in the vars file) |
| Node.js, Python, Git, gh, ripgrep, jq, curl | Choco packages (versions from the vars file) |
| Go, Vim, NuGet, make, MinGW-w64 | Choco packages (versions from the vars file) |
| Rust | Via rustup (arm64 host toolchain + MSVC targets for x86_64/i686/aarch64), `rust`/`cargo` on PATH |
| VS2022 Build Tools | Choco + `setup.exe` finalizer: .NET 4.8/.NET Core SDKs, VC++ workload (x86/x64/ARM/ARM64), CMake, Windows 11 SDK |
| WiX, protoc, NASM, LLVM | Choco packages (versions from the vars file) |
| Visual Studio Code | Native arm64 build, latest stable, direct download; `code` on PATH |
| Google Chrome | Chrome for Testing snapshot, hash-pinned (see the vars file); x64, runs under Prism emulation |
| Firefox | Choco package (x64, runs under Prism emulation) |
| OpenCode (`opencode-ai`) | npm global |
| OpenCodeReview (`ocr`) | npm global (`@alibaba-group/open-code-review`) |
| OpenChamber web UI | npm global (`@openchamber/web`), native service on `0.0.0.0:4000` |
| OpenSSH Server + RDP | Enabled; Administrator/sandbox1 (see the vars file) |
| Docker CLI | Client only (`docker` + `docker compose`), remote engine via the host bridge |
| Bridge tooling | Node relays (in-image `node.exe`, written by the runner) + host `socat` for the SSH-agent/Docker bridges; `C:\tools\socat.exe` + `npiperelay.exe` ship as utilities |

## Versioning

Same convention as the macOS images: the image version lives in
`image_version` in the vars file; every release bumps it, adds a
`CHANGELOG.md` entry, and creates a `windows-arm64-qemu-v<version>` git
tag via `./scripts/tag.sh <image>`.

## Running and publishing

- Run the sandbox: `./scripts/run-windows-sandbox.sh` — boots the qcow2
  under QEMU + swtpm, forwards SSH/RDP/OpenChamber ports, and bridges the
  host's Docker engine and SSH agent into the guest (see
  [docs/windows-qemu.md](../../docs/windows-qemu.md)).
- Publish: `./scripts/deploy.sh sandbox-windows-11` pushes the qcow2 to
  `ghcr.io/<owner>/sandbox-windows-11:<version>` + `:latest` as an OCI
  artifact via `oras` (the platform ships its own deploy wrapper —
  `images/windows-arm64-qemu/deploy.sh` — because `tart push` only works
  for Tart VMs). Needs `brew install oras` and a GHCR token with
  `write:packages` (`oras login ghcr.io`).

## Gotchas

- **The Windows ISO is not in the repo.** The build fails fast without
  `WINDOWS_ISO_PATH`; the sha256 in the vars file protects against a
  corrupt download.
- **ARM64 only.** x86_64 Windows under QEMU on Apple Silicon runs on TCG
  (pure emulation) and is unusably slow; HVF only virtualizes ARM64.
- **virtio-win ≥ 0.1.240** is required for ARM64 driver builds; older
  releases fail at the driver-staging step.
- **No shared folder.** The virtio-fs driver has no ARM64 Windows build
  (virtio-win issue #1337), so there is no host-directory mount like the
  macOS image's shared `dev` volume — use git, RDP clipboard, or the
  OpenChamber web UI instead.
- **Unactivated Windows.** The image runs indefinitely with a desktop
  watermark; personalization (wallpaper) is locked.
- **`qemuargs` replaces, not appends.** Any change that needs extra qemu
  args belongs in `qemu-with-tpm.sh`, not in the template's `qemuargs`.
- **USB enumeration order is load-bearing.** The install ISO's
  usb-storage device must precede virtio-win.iso's, or EDK2 drops to the
  EFI Shell instead of booting Setup — keep the argv layout in
  `qemu-with-tpm.sh` intact.
- **Computer name ≤ 15 chars.** `win11-sandbox` fits; longer names fail
  the specialize pass even though `xmllint`/`packer validate` pass.
