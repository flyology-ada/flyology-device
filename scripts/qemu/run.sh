#!/bin/sh
#  Boots and drives the test virtual machine.
#
#  Two virtual PCI devices are attached, and which two is not a free choice.
#  edu is QEMU's educational device: one MMIO BAR, a handful of registers,
#  and a DMA engine that dereferences whatever address it is given, which is
#  what makes it able to prove an IOMMU mapping is correct rather than
#  merely accepted. pci-testdev exercises MMIO and port access patterns.
#
#  ivshmem would have been the third, and is not here because QEMU 10.2 has
#  no ivshmem device at all: it was deprecated upstream and dropped. Nothing
#  in this repository can test against it until a QEMU that still has it is
#  available.
#
#  The guest is where the tests that need a kernel run: hugepages, an IOMMU,
#  and devices that can be bound to vfio-pci without taking anything away
#  from a running system.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
state=${FLYOLOGY_DEVICE_VM_STATE:-"$repo_root/build/vm"}
#  Unix socket paths are limited to about a hundred bytes, which a path
#  under a repository in a home directory can exceed on its own. The sockets
#  therefore live under a short symlink to the state directory.
short=${FLYOLOGY_DEVICE_VM_SOCKETS:-/tmp/flyology-device-vm}

image_url=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-arm64.qcow2
image_name=debian-12-nocloud-arm64.qcow2

case "$(uname -m)" in
  arm64|aarch64) guest_arch=aarch64 ;;
  *) printf '%s\n' "This harness targets aarch64 hosts." >&2; exit 2 ;;
esac

firmware=${FLYOLOGY_DEVICE_VM_FIRMWARE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}
firmware_vars=${FLYOLOGY_DEVICE_VM_FIRMWARE_VARS:-/opt/homebrew/share/qemu/edk2-arm-vars.fd}

usage () {
  printf '%s\n' \
    "usage: $0 {up|down|exec <command>|test|status}" \
    "" \
    "  up      boot the guest; the first run downloads a cloud image" \
    "  down    shut the guest down" \
    "  exec    run a shell command in the guest and print its output" \
    "  test    build both crates for Linux and run every suite in the guest" \
    "  status  report whether the guest is running" >&2
}

vm_pidfile="$state/qemu.pid"

#  Which virtual devices the guest gets. Overridable so that a candidate can
#  be tried without editing this file; the default is the set the test
#  suites cover.
#
#  Two edu devices rather than one, deliberately: they land in separate
#  IOMMU groups, which is the only way to exercise a container holding more
#  than one group, and the only way to demonstrate that a container is one
#  shared address space rather than a per-device one.
#
#  e1000e carries an option ROM the firmware will try to network-boot from,
#  which adds a long pause to every boot; romfile= removes it. A display
#  device is deliberately absent: it gives the firmware a graphics console
#  and the serial boot this harness drives never completes.
#
#  MAC and serial number are fixed rather than left to default, because the
#  tests read them back out of the devices and compare. A value chosen here
#  and recovered through MMIO is worth more than a self-consistency check.
#
#  The Intel controller shares a virtual hub with two other things rather
#  than having a backend to itself, and the reason is worth stating.
#
#  A loopback test proves a device agrees with itself. Both directions run
#  through the same emulated code and a frame that is wrong in some way that
#  code does not care about comes back looking correct. QEMU's user
#  networking is one step better — it answers address resolution for its
#  gateway, so a reply arrives from something that is not the device — but
#  it is a translation layer rather than a protocol stack, and it terminates
#  what it is sent.
#
#  So the hub also carries a network card the guest kernel keeps. That gives
#  the tests a real stack on the same wire: one that answers address
#  resolution, replies to echo requests, refuses connections to closed ports
#  with a reset, and reports unreachable ports — all of which require the
#  frames it is sent to be correct in every field, because a stack silently
#  drops a segment whose checksum is wrong rather than complaining about it.
#  A reply is therefore proof the frame was right, which no amount of
#  looping back to the sender can establish.
#
#  It is a virtio card and not a second Intel one on purpose. The tests bind
#  devices to vfio-pci by their identity, so a second controller of the same
#  model would be bound too and the kernel would lose the interface this
#  depends on.
#
#  Nothing else is on that hub, and QEMU's user networking in particular is
#  kept off it. That stack does not merely translate: it believes it owns
#  the addresses on its network, and a connection opened by hand from an
#  address it has never leased is one it answers with a reset — sent from
#  the address the connection came from, so it arrives looking exactly like
#  the far end changing its mind. It is a plausible-looking reply from a
#  third party that was never addressed, which is the hardest kind of
#  interference to attribute.
device_mac=${FLYOLOGY_DEVICE_VM_MAC:-52:54:00:12:34:56}
peer_mac=${FLYOLOGY_DEVICE_VM_PEER_MAC:-52:54:00:12:34:57}
device_serial=${FLYOLOGY_DEVICE_VM_NVME_SERIAL:-flyology0001}

devices=${FLYOLOGY_DEVICE_VM_DEVICES:-"
  -device edu
  -device edu
  -device pci-testdev
  -device nvme-subsys,id=nvmesubsys,nqn=flyology-device
  -drive id=nvmedisk,file=$state/nvme.qcow2,if=none,format=qcow2
  -drive id=nvmezoned,file=$state/nvme-zoned.qcow2,if=none,format=qcow2
  -drive id=nvmespare,file=$state/nvme-spare.qcow2,if=none,format=qcow2
  -drive id=nvmefat,file=$state/nvme-fat.qcow2,if=none,format=qcow2
  -device nvme,subsys=nvmesubsys,serial=$device_serial,msix_qsize=8
  -device nvme-ns,drive=nvmedisk,nsid=1
  -device nvme-ns,drive=nvmezoned,nsid=2,zoned=on,zoned.zone_size=1M,zoned.zone_capacity=1M
  -device nvme-ns,drive=nvmespare,nsid=3,detached=on
  -device nvme-ns,drive=nvmefat,nsid=4
  -netdev hubport,id=hubwire,hubid=1
  -device e1000e,netdev=hubwire,mac=$device_mac,romfile=
  -netdev hubport,id=hubpeer,hubid=1
  -device virtio-net-pci,netdev=hubpeer,mac=$peer_mac,romfile=
"}

is_running () {
  [ -f "$vm_pidfile" ] && kill -0 "$(cat "$vm_pidfile")" 2>/dev/null
}

do_up () {
  if is_running; then
    printf '%s\n' "the guest is already running" >&2
    return 0
  fi

  mkdir -p "$state/share"
  ln -sfn "$state" "$short"

  if [ ! -f "$state/$image_name" ]; then
    printf '%s\n' "downloading $image_name (about 400 MiB, once)" >&2
    curl -fsSL -o "$state/$image_name.part" "$image_url"
    mv "$state/$image_name.part" "$state/$image_name"
  fi

  #  The firmware variable store remembers boot entries for devices that
  #  are later removed, and then hangs waiting for them. Rebuilding it
  #  whenever the device set changes costs a few seconds of boot and saves
  #  a confusing hang.
  device_stamp="$state/devices.stamp"
  if [ ! -f "$device_stamp" ] \
    || [ "$(cat "$device_stamp")" != "$devices" ]
  then
    rm -f "$state/vars.fd"
    printf '%s' "$devices" > "$device_stamp"
  fi

  [ -f "$state/vars.fd" ] || cp "$firmware_vars" "$state/vars.fd"
  [ -f "$state/overlay.qcow2" ] || qemu-img create -q -f qcow2 \
    -b "$state/$image_name" -F qcow2 "$state/overlay.qcow2" 20G

  #  Three namespaces rather than one, because several NVMe command sets
  #  exist only on a namespace configured for them. Namespace one is
  #  ordinary and carries the block tests. Namespace two is zoned, which is
  #  the only way the zone commands become more than entries in a
  #  command-set table. Namespace three starts detached, so that attaching
  #  it is something a test can do.
  #
  #  Reservations have no such option: QEMU's NVMe advertises the three
  #  reservation commands and offers no configuration under which they
  #  work, so they stay unexercised and the README says why.
  for backing in nvme nvme-zoned nvme-spare nvme-fat; do
    [ -f "$state/$backing.qcow2" ] || qemu-img create -q -f qcow2 \
      "$state/$backing.qcow2" 64M
  done

  rm -f "$short/console.sock"

  #  iommu=smmuv3 is what makes this worth doing: without an emulated
  #  IOMMU the guest has no /dev/vfio groups and nothing here can run.
  #  Started in a session of its own. Without that, whatever reaps the
  #  shell that launched the guest — a timeout, a CI step ending, a
  #  terminal closing — signals the whole process group and takes the guest
  #  with it, and the next command reports a guest that is not running for
  #  no visible reason. setsid does this on Linux and does not exist on
  #  macOS, so the launcher is a three-line Python script that calls
  #  setsid(2) directly and is present wherever the console driver is.
  "$repo_root/scripts/qemu/detach.py" qemu-system-"$guest_arch" \
    -machine virt,accel=hvf,gic-version=3,iommu=smmuv3 \
    -cpu host -smp 4 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$firmware" \
    -drive if=pflash,format=raw,file="$state/vars.fd" \
    -drive if=virtio,format=qcow2,file="$state/overlay.qcow2" \
    -fsdev local,id=share,path="$state/share",security_model=none \
    -device virtio-9p-pci,fsdev=share,mount_tag=share \
    $devices \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -display none \
    -serial unix:"$short/console.sock",server,nowait \
    -pidfile "$vm_pidfile" \
    > "$state/qemu.log" 2>&1 &

  printf '%s\n' "waiting for the guest to reach a login prompt" >&2
  if ! "$repo_root/scripts/qemu/console.py" wait; then
    printf '%s\n' "" "the guest did not boot. QEMU said:" >&2
    tail -20 "$state/qemu.log" >&2
    exit 1
  fi
  printf '%s\n' "guest is up" >&2
}

do_down () {
  if ! is_running; then
    printf '%s\n' "the guest is not running" >&2
    return 0
  fi
  kill "$(cat "$vm_pidfile")" 2>/dev/null || true
  rm -f "$vm_pidfile"
  printf '%s\n' "guest stopped" >&2
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  status)
    if is_running; then printf '%s\n' "running"; else printf '%s\n' "stopped"; fi
    ;;
  exec)
    shift
    [ $# -ge 1 ] || { usage; exit 2; }
    is_running || { printf '%s\n' "the guest is not running; run: $0 up" >&2; exit 2; }
    exec "$repo_root/scripts/qemu/console.py" exec "$*"
    ;;
  test)
    is_running || do_up
    exec "$repo_root/scripts/qemu/test.sh"
    ;;
  *) usage; exit 2 ;;
esac
