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

#  Which virtual devices the guest gets. Overridable so that a device can be
#  tried without editing this file, but the default is the set the test
#  suites actually cover.
devices=${FLYOLOGY_DEVICE_VM_DEVICES:-"-device edu -device pci-testdev"}

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

  [ -f "$state/vars.fd" ] || cp "$firmware_vars" "$state/vars.fd"
  [ -f "$state/overlay.qcow2" ] || qemu-img create -q -f qcow2 \
    -b "$state/$image_name" -F qcow2 "$state/overlay.qcow2" 20G

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
