#!/bin/sh
#  Reports whether this host can open a VFIO container, and changes nothing.
#
#  It will not load a module, will not enable an IOMMU, and above all will
#  not unbind a device from its driver. Taking a device away from a running
#  kernel driver is a decision for whoever owns the machine; done to the
#  wrong device it takes the machine down.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$repo_root/scripts/find-alr.sh")

cd "$crate_root/showcases"
"$alr" -n build >/dev/null
exec "$crate_root/showcases/bin/host_readiness"
