#!/bin/sh
#  Builds and runs the device tests.
#
#  These need a machine with the devices attached and bound to vfio-pci,
#  which is what scripts/qemu in the repository root provides. Anywhere
#  else, each test reports that it could not find its device and says how
#  one would be provided, rather than passing quietly having checked
#  nothing.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$repo_root/scripts/find-alr.sh")

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
