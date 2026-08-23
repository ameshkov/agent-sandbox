#!/bin/sh

# Pushes locally built sandbox images to GHCR.
#
# Usage:
#   ./scripts/deploy.sh             # push every image
#   ./scripts/deploy.sh <image>     # push just one image (e.g. sandbox-macos-tahoe)
#
# Each image is pushed under
#   ghcr.io/<owner>/<image>:<image_version>
#   ghcr.io/<owner>/<image>:latest
# where <owner> is derived from the git remote (override with the GHCR_OWNER
# env var) and <image_version> is read from the image's vars file.
#
# Prerequisite: authenticate against GHCR once with a token that has
# `packages:write`:
#   tart login ghcr.io
# See DEVELOPMENT.md for details.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

requested="${1:-}"

owner="${GHCR_OWNER:-}"
if [ -z "$owner" ]; then
    owner=$(
        git config --get remote.origin.url 2>/dev/null |
            sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#/[^/]*$##'
    )
fi
if [ -z "$owner" ]; then
    echo "Could not determine the GHCR owner from the git remote." >&2
    echo "Set the GHCR_OWNER env var, e.g. GHCR_OWNER=my-org ./scripts/deploy.sh" >&2
    exit 1
fi

# Prints the name of every image (i.e. the name of every vars file).
list_images() {
    for vars_file in "$repo_root"/images/*/vars/*.pkrvars.hcl; do
        [ -f "$vars_file" ] || continue
        basename "$vars_file" .pkrvars.hcl
    done
}

# Prints the path of the vars file for the given image, or exits if missing.
find_vars_file() {
    image_name="$1"
    for vars_file in "$repo_root"/images/*/vars/"${image_name}".pkrvars.hcl; do
        [ -f "$vars_file" ] || continue
        printf '%s\n' "$vars_file"
        return 0
    done
    echo "No vars file found for image '$image_name'." >&2
    echo "Expected images/<platform>/vars/$image_name.pkrvars.hcl" >&2
    exit 1
}

deploy_image() {
    image_name="$1"
    vars_file=$(find_vars_file "$image_name")
    platform_dir=$(dirname "$(dirname "$vars_file")")

    # Platforms may ship their own deploy wrapper (e.g. the Windows image
    # is a qcow2 that must be pushed with oras, not tart). Delegate when
    # one exists; the wrapper resolves the vars file itself.
    if [ -f "$platform_dir/deploy.sh" ]; then
        "$platform_dir/deploy.sh" "$image_name"
        return
    fi

    image_version=$(sed -n \
        's/^[[:space:]]*image_version[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
        "$vars_file")
    if [ -z "$image_version" ]; then
        echo "Could not read image_version from $vars_file" >&2
        exit 1
    fi

    # Images are pushed flat under the owner: the platform is already part of
    # the image name (e.g. `sandbox-macos-tahoe`), so the GHCR package name
    # equals the image name.
    registry_path="ghcr.io/$owner/$image_name"

    echo "Pushing image: $image_name"
    echo "Registry: $registry_path:$image_version and :latest"

    # Chunked uploads (in MB): GHCR only supports chunks smaller than 4MB,
    # so 3MB keeps us under the limit.
    tart push "$image_name" \
        --chunk-size 3 \
        "$registry_path:$image_version" \
        "$registry_path:latest"
}

if [ -n "$requested" ]; then
    deploy_image "$requested"
else
    images=$(list_images)
    if [ -z "$images" ]; then
        echo "No images found: no vars files under images/*/vars/." >&2
        exit 1
    fi
    echo "Deploying all images:"
    echo "$images"
    for image in $images; do
        deploy_image "$image"
    done
fi
