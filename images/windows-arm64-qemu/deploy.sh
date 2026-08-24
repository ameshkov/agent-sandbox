#!/bin/bash
# images/windows-arm64-qemu/deploy.sh — publish the Windows sandbox image to GHCR.
#
# Invoked by scripts/deploy.sh, which delegates to a platform's deploy.sh
# when one exists (mirroring the build.sh delegation). The macOS images are
# pushed with `tart push`; the Windows image is a qcow2 file, so it is
# pushed to GHCR as an OCI artifact with oras.
#
# Usage:
#   images/windows-arm64-qemu/deploy.sh [<image>]
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
    echo "       pass the image name explicitly (e.g. sandbox-windows-11-arm64-qemu)." >&2
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

build_dir="$repo_root/build/windows-arm64-qemu"
artifact="$build_dir/output/${image_name}.qcow2"
if [ ! -f "$artifact" ]; then
  echo "ERROR: no built image at $artifact" >&2
  echo "       Build it first: WINDOWS_ISO_PATH=/path/to/iso ./scripts/build.sh $image_name" >&2
  exit 1
fi

command -v oras >/dev/null 2>&1 || {
  echo "ERROR: oras is not installed on PATH." >&2
  echo "       Install with: brew install oras" >&2
  exit 1
}

# ---- push ------------------------------------------------------------------
#
# OCI artifact: the qcow2 travels as one layer of an OCI artifact manifest
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
# e.g. scripts/run-windows-qemu-sandbox.sh expects sandbox-windows-11-arm64-qemu.qcow2),
# and it rejects absolute paths by default.
(
  cd "$build_dir/output" &&
    oras push \
      --artifact-type "application/vnd.agent-sandbox.qcow2" \
      "$ref" \
      "${image_name}.qcow2:application/vnd.oci.image.layer.v1.tar"
)

echo "Done: $registry_path:$image_version (and :latest)"
