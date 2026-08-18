#!/bin/sh
#  Builds both crates for Linux and runs every suite inside the guest.
#
#  This is the only environment in the repository where the hugepage paths
#  and the VFIO paths both run. The container can build them and a macOS
#  host can build most of them, but neither can execute them: a container
#  shares a kernel with no hugetlbfs and no IOMMU, and macOS has neither
#  concept.
#
#  Everything is built with gprbuild through the crates' own project files,
#  which declare Object_Dir and Exec_Dir. Nothing here calls gnatmake: it
#  writes its objects and its generated binder sources into whatever the
#  current directory happens to be, which is how this repository twice
#  ended up with build output scattered across its source tree.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
state=${FLYOLOGY_DEVICE_VM_STATE:-"$repo_root/build/vm"}
staging="$state/share"

mkdir -p "$staging"

#  Built in the Linux container rather than in the guest: the guest is a
#  bare cloud image with no compiler, and putting one there would be a
#  second thing to keep working.
printf '%s\n' "building for Linux" >&2
"$repo_root/scripts/linux/run.sh" sh -c '
set -e
for project in \
  flyology_dma/tests/flyology_dma_tests.gpr \
  flyology_dma/showcases/flyology_dma_showcases.gpr \
  flyology_vfio/tests/flyology_vfio_tests.gpr \
  flyology_vfio/showcases/flyology_vfio_showcases.gpr \
  flyology_vfio_qemu/tests/flyology_vfio_qemu_tests.gpr
do
  printf "  %s\n" "$project" >&2
  gprbuild -q -p -j0 -P "$project"
done
'

"$repo_root/scripts/check-tree-clean.sh"

#  Names collide between crates — both have a host_readiness — so each is
#  staged under a name that says where it came from.
stage () {
  crate=$1 kind=$2 prefix=$3
  for program in "$repo_root/$crate/$kind/bin/"*; do
    [ -x "$program" ] || continue
    cp "$program" "$staging/$prefix$(basename "$program")"
  done
}

rm -f "$staging"/*
stage flyology_dma tests ""
stage flyology_dma showcases "dma_"
stage flyology_vfio tests ""
stage flyology_vfio showcases "vfio_"
stage flyology_vfio_qemu tests ""
printf '%s\n' "staged $(ls "$staging" | wc -l | tr -d ' ') programs" >&2

#  Hugepages are reserved here rather than by any library: reserving them
#  changes a machine's global state, and nothing in this repository makes
#  that decision for its host. This guest exists to be changed.
#  A long timeout: the console is a serial line, and a full suite run
#  produces more output than a quick command does.
FLYOLOGY_DEVICE_VM_TIMEOUT=${FLYOLOGY_DEVICE_VM_TIMEOUT:-600}
export FLYOLOGY_DEVICE_VM_TIMEOUT

run_in_guest () {
  "$repo_root/scripts/qemu/run.sh" exec "$1"
}

run_in_guest 'mkdir -p /mnt/share; mountpoint -q /mnt/share || mount -t 9p -o trans=virtio,version=9p2000.L share /mnt/share; echo 512 > /proc/sys/vm/nr_hugepages; echo 1 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null; grep -i hugepages_total /proc/meminfo'

status=0
for suite in scalar_tests address_space_tests region_tests mapper_tests \
             pool_tests thin_tests lifecycle_tests; do
  printf '\n== %s ==\n' "$suite"
  run_in_guest "/mnt/share/$suite" || status=1
done

#  The device tests need their devices bound to vfio-pci, and two of them
#  are claimed by kernel drivers first. Unbinding is done here, on a guest
#  that exists to be changed, for a fixed list of device identifiers that
#  belong to this harness — never by a library, never by identifier
#  discovery, and never on a machine anyone depends on. Unbinding the wrong
#  device takes a machine down.
run_in_guest 'modprobe vfio-pci 2>/dev/null
for d in /sys/bus/pci/devices/*; do
  a=$(basename $d)
  case "$(cat $d/vendor):$(cat $d/device)" in
    0x1234:0x11e8|0x1b36:0x0005|0x1b36:0x0010|0x8086:0x10d3) ;;
    *) continue ;;
  esac
  if [ -e "$d/driver" ]; then
    echo "$a" > "$d/driver/unbind" 2>/dev/null
  fi
  echo vfio-pci > "$d/driver_override"
  echo "$a" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null
  printf "bound %s (%s:%s) group %s\n" "$a" "$(cat $d/vendor)" \
    "$(cat $d/device)" "$(basename $(readlink $d/iommu_group))"
done'

#  The values the guest was started with are passed to the tests that read
#  them back out of a device, so that the harness and the tests cannot
#  disagree about what the corpus is. A test that made up its own expected
#  value would be checking itself.
corpus="FLYOLOGY_DEVICE_VM_MAC=${FLYOLOGY_DEVICE_VM_MAC:-52:54:00:12:34:56}"
corpus="$corpus FLYOLOGY_DEVICE_VM_NVME_SERIAL=${FLYOLOGY_DEVICE_VM_NVME_SERIAL:-flyology0001}"

for suite in edu_tests container_sharing_tests pci_testdev_tests \
             nvme_tests e1000e_tests \
             nvme_coverage_tests e1000e_coverage_tests msix_tests \
             nvme_queues_tests; do
  printf '\n== %s ==\n' "$suite"
  run_in_guest "$corpus /mnt/share/$suite" || status=1
done

printf '\n== dma_region_walkthrough ==\n'
run_in_guest /mnt/share/dma_region_walkthrough || status=1

printf '\n== vfio_host_readiness ==\n'
run_in_guest /mnt/share/vfio_host_readiness || status=1

exit "$status"
