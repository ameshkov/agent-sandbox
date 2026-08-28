#!/bin/bash
# images/ubuntu-arm64-vmware/deploy.sh — publish the Ubuntu sandbox image
# to GHCR.
#
# Invoked by scripts/deploy.sh, which delegates to a platform's deploy.sh
# when one exists (mirroring the build.sh delegation). The macOS images are
# pushed with `tart push`; the Ubuntu image is plain files, so it is pushed
# to GHCR as an OCI artifact with oras — the whole .vmx output directory
# (vmx + vmdk + nvram), packed into a single tar.gz that consumers extract
# and clone.
#
# Usage:
#   images/ubuntu-arm64-vmware/deploy.sh [<image>]
#
# <image> defaults to the single vars file in vars/ (must be passed when
# more than one image exists).
#
# The image is pushed flat under
#   ghcr.io/<owner>/<image>:<image_version>   (also tagged :latest)
# where <owner> is derived from the git remote (override with GHCR_OWNER)
# and <image_version> is read from the image's vars file.
#
# Prerequisite: authenticate against GHCR once with a token that has
# `write:packages`:
#   oras login ghcr.io -u <user> --password-stdin
# (oras also picks up credentials from ~/.docker/config.json, e.g. after a
# `docker login ghcr.io`.)
#
# Environment:
#   GHCR_OWNER  — GHCR owner to push under (default: from the git remote)

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
platform_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# ---- image / vars resolution ----------------------------------------------

requested="${1:-}"
if [ -n "$requested" ]; then
  image_name="$requested"
else
  vars_files=("$platform_dir"/vars/*.pkrvars.hcl)
  if [ "${#vars_files[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one vars file in $platform_dir/vars/," >&2
    echo "       pass the image name explicitly (e.g. sandbox-ubuntu-24-04-arm64-vmware)." >&2
    exit 1
  fi
  image_name=$(basename "${vars_files[0]}" .pkrvars.hcl)
fi
vars_file="$platform_dir/vars/${image_name}.pkrvars.hcl"
if [ ! -f "$vars_file" ]; then
  echo "ERROR: expected $vars_file (image name = vars file name)." >&2
  exit 1
fi

# ---- owner ----------------------------------------------------------------

owner="${GHCR_OWNER:-}"
if [ -z "$owner" ]; then
  owner=$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null |
    sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#/[^/]*$##')
fi
if [ -z "$owner" ]; then
  echo "ERROR: could not determine the GHCR owner from the git remote." >&2
  echo "       Set GHCR_OWNER, e.g. GHCR_OWNER=my-org." >&2
  exit 1
fi

# ---- image_version + artifact ---------------------------------------------

image_version=$(sed -n \
  's/^[[:space:]]*image_version[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
  "$vars_file")
if [ -z "$image_version" ]; then
  echo "ERROR: could not read image_version from $vars_file" >&2
  exit 1
fi

build_dir="$repo_root/build/ubuntu-arm64-vmware"
vmx="$build_dir/output/${image_name}.vmx"
if [ ! -f "$vmx" ]; then
  echo "ERROR: no built image at $vmx" >&2
  echo "       Build it first: UBUNTU_ISO_PATH=/path/to/iso ./scripts/build.sh $image_name" >&2
  exit 1
fi

# ---- package the VM directory ---------------------------------------------
#
# The vmware-iso builder leaves the runnable VM in output/ (vmx + vmdk +
# nvram; vmware.log and friends are noise). One tar.gz keeps the oras push
# single-file and gives consumers a single pull artifact to extract.

command -v tar >/dev/null 2>&1 || {
  echo "ERROR: tar is not available." >&2
  exit 1
}

artifact="$build_dir/output/${image_name}.tar.gz"
echo "==> packing $artifact (excluding vmware logs)"
(
  cd "$build_dir/output" &&
    tar -czf "$artifact" --exclude='*.log' ${image_name}.vmx ${image_name}.nvram *.vmdk
)

command -v oras >/dev/null 2>&1 || {
  echo "ERROR: oras is not installed on PATH." >&2
  echo "       Install with: brew install oras" >&2
  exit 1
}

# ---- push ------------------------------------------------------------------
#
# OCI artifact: the tar.gz travels as one layer of an OCI artifact manifest
# (no container image config needed). The media type is arbitrary for oras
# round-trips — consumers `oras pull` the file back by its name. Multiple
# tags are pushed in one go (1.0.0 + latest).

registry_path="ghcr.io/$owner/$image_name"
ref="$registry_path:$image_version,latest"

echo "Pushing image: $image_name"
echo "Registry: $registry_path:$image_version and :latest"
echo "Artifact: $artifact ($(du -h "$artifact" | awk '{print $1}'))"

# Push from the output dir with the bare file name: oras stores the file
# under the name it is given (consumers `oras pull` it back by that name,
# e.g. scripts/run-ubuntu-vmware-sandbox.sh expects
# sandbox-ubuntu-24-04-arm64-vmware.tar.gz), and it rejects absolute paths by
# default.
(
  cd "$build_dir/output" &&
    oras push \
      --artifact-type "application/vnd.agent-sandbox.vmware-vm" \
      "$ref" \
      "${image_name}.tar.gz:application/vnd.oci.image.layer.v1.tar"
)

echo "Done: $registry_path:$image_version (and :latest)"
