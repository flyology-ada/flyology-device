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
  flyology_vfio/showcases/flyology_vfio_showcases.gpr
do
  printf "  %s\n" "$project" >&2
  gprbuild -q -p -j0 -P "$project"
done

#  The device tests are built through Alire rather than gprbuild directly,
#  because one of them opens a socket with Flyology and so needs a crate
#  that is fetched from an index rather than found in this repository.
printf "  %s\n" "flyology_vfio_qemu/tests (through alr)" >&2
cd flyology_vfio_qemu/tests && alr -n build -- -q -j0
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

#  The peer the frame tests talk to. It is the guest's own kernel on the
#  same virtual hub as the controller under test, so a reply comes from a
#  protocol stack rather than from the device agreeing with itself.
#
#  A static address rather than one leased, because a test that has to
#  discover which address it is talking to cannot tell a wrong reply from no
#  reply. The interface is found by the address it was given rather than by
#  name, since names depend on probe order.
peer_mac=${FLYOLOGY_DEVICE_VM_PEER_MAC:-52:54:00:12:34:57}
#  Not 10.0.2.15: that is the address QEMU's own user networking hands
#  out by default, and a peer sharing it would make two things on the hub
#  answer for one address.
peer_ip=${FLYOLOGY_DEVICE_VM_PEER_IP:-10.0.2.50}

run_in_guest "for n in /sys/class/net/*; do
  [ \"\$(cat \$n/address 2>/dev/null)\" = \"$peer_mac\" ] || continue
  i=\$(basename \$n)
  ip link set \$i up
  ip addr flush dev \$i 2>/dev/null
  ip addr add $peer_ip/24 dev \$i
  printf 'peer %s is %s at %s\n' \$i $peer_mac $peer_ip
done"

#  The values the guest was started with are passed to the tests that read
#  them back out of a device, so that the harness and the tests cannot
#  disagree about what the corpus is. A test that made up its own expected
#  value would be checking itself.
corpus="FLYOLOGY_DEVICE_VM_MAC=${FLYOLOGY_DEVICE_VM_MAC:-52:54:00:12:34:56}"
corpus="$corpus FLYOLOGY_DEVICE_VM_NVME_SERIAL=${FLYOLOGY_DEVICE_VM_NVME_SERIAL:-flyology0001}"
corpus="$corpus FLYOLOGY_DEVICE_VM_PEER_MAC=$peer_mac FLYOLOGY_DEVICE_VM_PEER_IP=$peer_ip"

for suite in edu_tests container_sharing_tests pci_testdev_tests \
             nvme_tests e1000e_tests \
             nvme_coverage_tests e1000e_coverage_tests msix_tests \
             nvme_queues_tests nvme_zoned_tests nvme_copy_tests nvme_blocks_tests e1000e_filter_tests e1000e_queues_tests e1000e_peer_tests; do
  printf '\n== %s ==\n' "$suite"
  run_in_guest "$corpus /mnt/share/$suite" || status=1
done

#  The filesystem suite, which is three turns rather than one.
#
#  A disk has one owner at a time. The kernel cannot mount a namespace this
#  driver has taken, and this driver must not write to one the kernel has
#  mounted, so the namespace is handed between them rather than shared. Each
#  turn runs with the other side detached, which is not a simplification —
#  it is the only correct way for two drivers to use one disk.
#
#  Done here rather than by the test, because binding a device to a driver
#  belongs to whoever owns the machine. This one is disposable and exists to
#  be changed; nothing in the crates does anything of the kind.
nvme_address=${FLYOLOGY_DEVICE_VM_NVME:-0000:00:05.0}

give_nvme_to () {
  run_in_guest "d=/sys/bus/pci/devices/$nvme_address
    [ -e \$d/driver ] && basename \$(readlink \$d/driver) > /tmp/held || true
    [ -e \$d/driver ] && echo $nvme_address > \$d/driver/unbind 2>/dev/null
    echo $1 > \$d/driver_override
    echo $nvme_address > /sys/bus/pci/drivers/$1/bind 2>/dev/null
    sleep 1
    printf 'nvme is now with %s\n' \$(basename \$(readlink \$d/driver))"
}

#  A filesystem made fresh every run, rather than one kept between them.
#
#  A test that reuses a filesystem accumulates the leavings of every run
#  before it: a file rewritten in a new place leaves the old copy in a block
#  nothing has reclaimed, and a search that takes the first match finds the
#  wrong one. Making it again costs a moment and removes the whole class.
#
#  The payload also ends in a token this run and no earlier one used, which
#  covers what remaking the filesystem does not: mkfs rewrites the
#  bookkeeping and leaves the data blocks as they were.
fs_token=$(date +%H%M%S)
fs_corpus="$corpus FLYOLOGY_DEVICE_FS_TOKEN=$fs_token"

printf '\n== nvme_file_tests ==\n'
give_nvme_to nvme
#  Found by its namespace identifier rather than by its name, because they
#  are not the same number and nothing says they should be: a namespace
#  that starts detached takes an identifier and no name, so namespace four
#  arrives as nvme0n3. Guessing the name gets the wrong disk or none.
find_namespace='n=""
  for b in /sys/block/nvme*; do
    [ -f "$b/nsid" ] || continue
    [ "$(cat $b/nsid)" = "4" ] || continue
    n=/dev/$(basename $b)
  done'

run_in_guest "$find_namespace
  [ -b \"\$n\" ] || { echo 'no block device for namespace 4'; exit 1; }
  mkdir -p /mnt/nvme
  mkfs.ext2 -q -F -L FLYOLOGY \"\$n\" >/dev/null
  mount \"\$n\" /mnt/nvme
  printf 'namespace 4 is %s, mounted at /mnt/nvme\n' \"\$n\"" || status=1
run_in_guest "$fs_corpus /mnt/share/nvme_file_tests write" || status=1
run_in_guest 'sync; umount /mnt/nvme; echo unmounted' || status=1

give_nvme_to vfio-pci
run_in_guest "$fs_corpus /mnt/share/nvme_file_tests find" || status=1

give_nvme_to nvme
run_in_guest "$find_namespace
  mount \"\$n\" /mnt/nvme && echo remounted" || status=1
run_in_guest "$fs_corpus /mnt/share/nvme_file_tests read" || status=1
run_in_guest 'umount /mnt/nvme 2>/dev/null; echo done' || status=1

#  Left as the other suites expect to find it.
give_nvme_to vfio-pci

printf '\n== dma_region_walkthrough ==\n'
run_in_guest /mnt/share/dma_region_walkthrough || status=1

printf '\n== vfio_host_readiness ==\n'
run_in_guest /mnt/share/vfio_host_readiness || status=1

exit "$status"
