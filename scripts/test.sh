#!/bin/sh
#  Repo-wide dispatcher: runs test.sh in every crate that has one.
#
#  The repository root is not a crate. Each crate owns its own scripts, and
#  this script exists only so that one command covers the whole repository.
#  Crates run in dependency order, so a failure in flyology_dma stops before
#  flyology_vfio builds against it.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

status=0
ran=0
for crate in flyology_dma flyology_vfio flyology_vfio_qemu; do
  script="$repo_root/$crate/scripts/test.sh"
  [ -x "$script" ] || continue
  ran=$((ran + 1))
  printf '\n== %s: %s ==\n' "$crate" "test"
  if ! "$script"; then
    status=1
  fi
done

#  A build that wrote outside its object directory is a defect in the build,
#  not a nuisance to be cleaned up afterwards. Checking here means every full
#  test run notices.
if ! "$repo_root/scripts/check-tree-clean.sh"; then
  status=1
fi

if [ "$ran" -eq 0 ]; then
  printf '%s\n' "No crate provides scripts/test.sh" >&2
  exit 2
fi

exit "$status"
