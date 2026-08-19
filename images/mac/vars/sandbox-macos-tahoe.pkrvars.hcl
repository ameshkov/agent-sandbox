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

# OpenChamber web UI password (host access: http://<vm-ip>:3000, see
# docs/macos.md). OpenChamber refuses to serve on the network without it.
openchamber_ui_password = "sandbox"

# Semantic version this image is published under (also the push tag, besides
# :latest).  Bump it and add a CHANGELOG.md entry for every release.
image_version = "1.1.0"
