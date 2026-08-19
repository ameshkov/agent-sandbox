#!/bin/sh

# Builds sandbox images with Packer.
#
# Usage:
#   ./scripts/build.sh             # build every image
#   ./scripts/build.sh <image>     # build just one image (e.g. sandbox-macos-tahoe)
#
# Images are discovered from the per-image vars files under
# images/<platform>/vars/<image>.pkrvars.hcl; the Packer template is the
# platform's *.pkr.hcl file. See DEVELOPMENT.md for details.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

requested="${1:-}"

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

build_image() {
    image_name="$1"
    vars_file=$(find_vars_file "$image_name")
    platform_dir=$(dirname "$(dirname "$vars_file")")

    template_file=
    for candidate in "$platform_dir"/*.pkr.hcl; do
        [ -f "$candidate" ] || continue
        template_file="$candidate"
        break
    done
    if [ -z "$template_file" ]; then
        echo "No Packer template (*.pkr.hcl) found in $platform_dir" >&2
        exit 1
    fi

    echo "Building image: $image_name"
    echo "Using template: $template_file"
    echo "Using vars: $vars_file"

    # Packer creates build artifacts relative to the template's directory.
    (cd "$platform_dir" &&
        packer init "$template_file" &&
        packer build -var-file="$vars_file" "$template_file")
}

if [ -n "$requested" ]; then
    build_image "$requested"
else
    images=$(list_images)
    if [ -z "$images" ]; then
        echo "No images found: no vars files under images/*/vars/." >&2
        exit 1
    fi
    echo "Building all images:"
    echo "$images"
    for image in $images; do
        build_image "$image"
    done
fi
