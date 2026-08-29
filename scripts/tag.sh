#!/bin/sh

# Creates and pushes the git release tag for an image.
#
# Usage:
#   ./scripts/tag.sh <image>     # tag one image (e.g. sandbox-macos-tahoe)
#   ./scripts/tag.sh             # tag every image
#
# The tag is <platform>-v<image_version>, where <platform> is the image's
# directory under images/ (e.g. `mac` → `mac-v1.2.0`) and <image_version> is
# read from the image's vars file.
#
# Run this right after committing a release and before build.sh + deploy.sh.
# The script enforces the release convention:
#   - the working tree must be clean, so the tag always points at the release
#     commit (commit the version bump + changelog entry first);
#   - the platform's CHANGELOG.md must have a `[<tag>]` entry, so every
#     version bump is recorded in the changelog;
#   - the tag must not exist yet.
# The tag is annotated and pushed to origin — the changelog's tag links
# resolve to it. See DEVELOPMENT.md → "Releasing a new image version".

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Prints the name of every image (i.e. the name of every vars file).
list_images() {
    for vars_file in "$repo_root"/images/*/vars/*.pkrvars.hcl; do
        [ -f "$vars_file" ] || continue
        basename "$vars_file" .pkrvars.hcl
    done
}

usage() {
    cat <<'EOF'
Usage: tag.sh [options] [image]

Creates and pushes the git release tag for an image. Without an <image>
argument, tags every image discovered from the per-image vars files under
images/<platform>/vars/<image>.pkrvars.hcl. The tag is
<platform>-v<image_version>, where <platform> is the image's directory
under images/ (e.g. `mac` → `mac-v1.2.0`) and <image_version> is read from
the image's vars file.

Run this right after committing a release and before build.sh + deploy.sh.
The script enforces the release convention: the working tree must be clean,
the platform's CHANGELOG.md must have a `[<tag>]` entry, and the tag must
not exist yet. See DEVELOPMENT.md → "Releasing a new image version".

Arguments:
  image                  image name to tag

Options:
  -h, --help   Show this help

Available images:
EOF
    list_images | sed 's/^/  /'
    cat <<'EOF'

Examples:
  ./scripts/tag.sh                    # tag every image
  ./scripts/tag.sh sandbox-macos-tahoe  # tag the macOS image
EOF
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
esac

requested="${1:-}"

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

tag_image() {
    image_name="$1"
    vars_file=$(find_vars_file "$image_name")
    platform_dir=$(dirname "$(dirname "$vars_file")")
    platform=$(basename "$platform_dir")

    image_version=$(sed -n \
        's/^[[:space:]]*image_version[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
        "$vars_file")
    if [ -z "$image_version" ]; then
        echo "Could not read image_version from $vars_file" >&2
        exit 1
    fi

    tag="$platform-v$image_version"
    changelog="$platform_dir/CHANGELOG.md"

    if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
        echo "Working tree is dirty — commit the version bump and CHANGELOG entry first." >&2
        exit 1
    fi

    if git -C "$repo_root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
        echo "Tag '$tag' already exists." >&2
        exit 1
    fi

    if [ ! -f "$changelog" ] || ! grep -q "## \[$tag\]" "$changelog"; then
        echo "No CHANGELOG entry for [$tag] in $changelog." >&2
        echo "Add it (and bump image_version) before tagging." >&2
        exit 1
    fi

    echo "Tagging: $tag ($image_name v$image_version)"
    git -C "$repo_root" tag -a "$tag" -m "Release $image_name v$image_version"
    git -C "$repo_root" push origin "$tag"
}

if [ -n "$requested" ]; then
    tag_image "$requested"
else
    images=$(list_images)
    if [ -z "$images" ]; then
        echo "No images found: no vars files under images/*/vars/." >&2
        exit 1
    fi
    echo "Tagging all images:"
    echo "$images"
    for image in $images; do
        tag_image "$image"
    done
fi
