#!/bin/sh
#  Reports what this host can currently support, and changes nothing.
#
#  Reserving hugepages and raising the locked-memory limit are decisions for
#  whoever owns the machine. This script says what is missing and what would
#  provide it; it does not write to /proc, /sys, or any limit.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$repo_root/scripts/find-alr.sh")

cd "$crate_root/showcases"
"$alr" -n build >/dev/null
exec "$crate_root/showcases/bin/host_readiness"
