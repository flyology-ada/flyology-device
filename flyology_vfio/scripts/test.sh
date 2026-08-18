#!/bin/sh
#  Builds and runs the flyology_vfio test programs.
#
#  These run on any host. What they check is the binding — request numbers,
#  struct layouts, and the diagnostics for a host with no VFIO — rather than
#  the kernel, so a machine with no IOMMU still gets a meaningful result.
#  Each test that needs a device reports a skip by name rather than passing
#  silently, so a run that checked almost nothing says so.
#
#  The half that needs a device lives in the flyology_vfio_qemu crate.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$repo_root/scripts/find-alr.sh")

#  Regenerating and diffing the kernel constants is part of the test suite,
#  not a separate chore: a request number that has drifted from the headers
#  fails here rather than as an EINVAL somewhere far away. It needs Linux
#  headers, so it runs where they exist and is reported as skipped where
#  they do not.
if [ -f /usr/include/linux/vfio.h ] || command -v docker >/dev/null 2>&1; then
  "$crate_root/scripts/verify-constants.sh"
else
  printf '%s\n' \
    "SKIP constant verification: no Linux headers and no container runtime" >&2
fi

cd "$crate_root/tests"
"$alr" -n build

status=0
for program in "$crate_root"/tests/bin/*; do
  [ -x "$program" ] || continue
  printf '\n== %s ==\n' "$(basename "$program")"
  if ! "$program"; then
    status=1
  fi
done

exit "$status"
