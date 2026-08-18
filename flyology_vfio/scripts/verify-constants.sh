#!/bin/sh
#  Fails when the committed constants no longer match the kernel headers.
#
#  Regenerates into a scratch file and diffs. Drift between the committed
#  numbers and the kernel becomes a test failure here rather than a confusing
#  EINVAL somewhere else much later.
#
#  The scratch file lives under the repository's ignored build directory
#  rather than in a system temporary directory, because on a host without
#  Linux headers the regeneration happens inside a container that can only
#  see the repository.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
committed="$crate_root/src/flyology_vfio-thin-constants.ads"
scratch="$repo_root/build/constants-check/flyology_vfio-thin-constants.ads"

mkdir -p "$(dirname -- "$scratch")"
trap 'rm -f "$scratch"' EXIT

"$crate_root/scripts/generate-constants.sh" "$scratch" >/dev/null

if diff -u "$committed" "$scratch"; then
  printf '%s\n' "flyology_vfio constants match the kernel headers"
else
  printf '%s\n' \
    "" \
    "The committed constants differ from this host's kernel headers." \
    "Run scripts/generate-constants.sh and review the change: an ioctl" \
    "number or a struct offset moving is worth reading carefully." >&2
  exit 1
fi
