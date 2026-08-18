#!/bin/sh
#  Regenerates src/flyology_vfio-thin-constants.ads from the Linux headers.
#
#  Every ioctl number, flag, struct size, and field offset this crate uses
#  comes from the kernel headers of the machine this runs on. None is
#  transcribed by hand: a wrong ioctl number produces EINVAL a long way from
#  the mistake, and a wrong field offset has the kernel reading one field
#  where another was meant.
#
#  This needs Linux headers. On a host that has none — macOS is the usual
#  development host here — it runs inside the repository's Linux container
#  instead, which is why the output is identical wherever it is run from.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
output=${1:-"$crate_root/src/flyology_vfio-thin-constants.ads"}

if [ ! -f /usr/include/linux/vfio.h ]; then
  if [ "${FLYOLOGY_VFIO_IN_CONTAINER:-}" = "1" ]; then
    printf '%s\n' \
      "No /usr/include/linux/vfio.h inside the container image." >&2
    exit 2
  fi
  printf '%s\n' \
    "No Linux headers here; regenerating in the Linux container." >&2
  FLYOLOGY_VFIO_IN_CONTAINER=1 \
    exec "$repo_root/scripts/linux/run.sh" \
      sh -c "FLYOLOGY_VFIO_IN_CONTAINER=1 ./flyology_vfio/scripts/generate-constants.sh ${output#$repo_root/}"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cc -O2 -Wall -Wextra -o "$work/generate" "$crate_root/scripts/generate-constants.c"
"$work/generate" > "$work/constants.ads"

mkdir -p "$(dirname -- "$output")"
mv "$work/constants.ads" "$output"
printf '%s\n' "wrote $output"
