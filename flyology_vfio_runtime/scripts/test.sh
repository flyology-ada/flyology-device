#!/bin/sh
#  Builds and runs the runtime adapter's tests.
#
#  These need no device. VFIO delivers an interrupt by making an eventfd
#  readable, and an eventfd can be made readable by writing to it, so the
#  waiter is checked against exactly what it will see in service without a
#  controller being present. They do need the Flyology runtime, which is
#  fetched from the Flyology index rather than pinned to a path.
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
