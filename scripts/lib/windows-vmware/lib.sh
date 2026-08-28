#!/bin/bash
# scripts/lib/windows-vmware/lib.sh — shared helpers for the Windows VMware
# sandbox.
#
# The helpers are generic (vmrun resolution, hardware-version upgrade,
# displayName) and now live in scripts/lib/vmware.sh; this file is kept as
# the source path the Windows build script and the Windows runner already
# use, so it just forwards. New consumers should source
# scripts/lib/vmware.sh directly.

# shellcheck source=scripts/lib/vmware.sh
source "$(dirname "${BASH_SOURCE[0]}")/../vmware.sh"
