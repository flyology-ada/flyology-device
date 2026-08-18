#!/bin/sh
#  Builds and runs the flyology_dma test programs.
#
#  Every test here runs on any host: the portable units need only ordinary
#  anonymous memory, and the hugepage checks adapt to what the host offers.
#  On a host with a hugepage pool they allocate from it; on a host without
#  one they assert that the failure names the missing pool instead of
#  quietly falling back to small pages. Run scripts/host-readiness.sh to see
#  which of those two a given host will do.
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
