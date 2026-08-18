#!/bin/sh
#  Proves the units where an off-by-one would corrupt host memory silently.
#
#  Two units are in scope, and the choice is deliberate rather than a
#  gesture at coverage. Flyology_DMA.Free_Lists is where two acquires
#  returning one slot would put two writers and a device on the same bytes.
#  Flyology_DMA.Address_Space is where an address running past the end of a
#  window would point a device at memory nobody mapped. Both are small, hold
#  no addresses, and touch no operating system.
#
#  The rest of the crate is deliberately outside the proof scope: regions
#  and mappers are controlled types over syscalls, which SPARK does not
#  cover, and claiming otherwise would be claiming more than has been shown.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$repo_root/scripts/find-alr.sh")
proof_level=${FLYOLOGY_PROOF_LEVEL:-1}

cd "$crate_root/proof"
"$alr" -n build --stop-after=generation
"$alr" -n gnatprove \
  -P "$crate_root/flyology_dma.gpr" \
  --mode=all \
  --level="$proof_level" \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u \
  flyology_dma-free_lists.adb \
  flyology_dma-address_space.adb

printf '%s\n' "flyology_dma proof suite finished"
