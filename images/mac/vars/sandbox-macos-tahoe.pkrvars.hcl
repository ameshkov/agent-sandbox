# macOS 26 (Tahoe) + Xcode 26.4.1
#
# The default sandbox image.  macos_version + xcode_version must point at a
# tag that exists in the Cirrus Labs base images on GHCR:
# https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos-
macos_version = "tahoe"
xcode_version = "26.4.1"

# Node.js version installed via nvm and set as the default.
node_version = "26"

# Homebrew Python version (also used for the unversioned python/pip aliases).
python_version = "3.14"

# VM resources
# disk_size must be >= the Cirrus base image disk (140 GB): tart can only
# grow a disk, never shrink it.
disk_size = 160
cpu_count = 4
memory_gb = 8

# SSH credentials for provisioning (fixed in the Cirrus Labs base images).
ssh_username = "admin"
ssh_password = "admin"

# OpenChamber web UI password (host access: http://<vm-ip>:4000, see
# docs/macos.md). OpenChamber refuses to serve on the network without it.
openchamber_ui_password = "sandbox"

# TCP port the OpenChamber web UI listens on inside the guest (host access:
# http://<vm-ip>:4000). 4000 — not the Vite dev-server default 3000 — so
# frontend dev servers don't collide with it. Keep
# scripts/run-macos-sandbox.sh's SANDBOX_OPENCHAMBER_PORT in sync.
openchamber_port = 4000

# Semantic version this image is published under (also the GHCR push tag,
# besides :latest).  For every release: bump it, add a CHANGELOG.md entry,
# and create the mac-v<version> git tag (./scripts/tag.sh <image>).
image_version = "1.5.0"
