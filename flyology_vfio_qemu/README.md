# flyology_vfio_qemu

A bring-up harness that drives QEMU's virtual PCI devices through
[`flyology_vfio`](../flyology_vfio/) and [`flyology_dma`](../flyology_dma/).

This is not a driver and is not meant to be depended on. It exists to answer
a question the crates below it cannot answer about themselves.

## Why it exists

`flyology_dma` can be tested against ordinary memory, and `flyology_vfio`
can be tested against the kernel's own refusals. Neither tells you whether
an I/O virtual address this code programmed is one a device can actually
follow. Only a device dereferencing that address can, and that needs a
device.

The value is concrete: this crate has already found bugs the other two
could not have found alone. An IOVA of 2⁴⁶ was accepted by
`VFIO_IOMMU_MAP_DMA` without complaint and then refused by the IOMMU, which
reports a 44-bit input address size — a mapping that succeeded and an
address nothing could translate. That failure is invisible until a device
tries to use it.

## Devices

| Device | Identity | What it exercises |
| --- | --- | --- |
| `edu` | `1234:11e8` | BAR mapping, MMIO of every width, ordered accesses, a computation with a completion flag, a DMA engine that follows an IOVA, interrupt delivery over eventfd |
| `pci-testdev` | `1b36:0005` | A second device that is not the one the crates were brought up on; an MMIO BAR and, usefully, an I/O port region that VFIO reports as unmappable |

`ivshmem` would have been a third. QEMU 10.2 has no ivshmem device at all —
it was deprecated upstream and dropped — so nothing here can test against
it. The crate is arranged so a third device is a new child package and a new
test program, nothing more.

## What it proves, and what it does not

It genuinely validates the IOMMU path. With an emulated SMMU, QEMU walks its
page tables when a device dereferences an address, so an IOVA programmed
incorrectly produces a translation fault rather than quietly working.

It validates nothing about hardware. There is no silicon here: no bus
timing, no errata, no write-combining, no MSI-X table with a sparse-mmap
hole, no 64-bit or multi-BAR layouts. A result from this crate is a result
about the binding.

One thing worth knowing that this crate taught, and that applies beyond it:
polling a device flat out can prevent it making progress. An emulated device
is driven by its emulator's main loop, and a guest issuing register reads
without pause can starve it. The poll loops here wait between reads.

## Running

The devices must exist and be bound to `vfio-pci`, which is what the
repository's virtual machine provides:

```sh
scripts/qemu/run.sh up
scripts/qemu/test.sh
```

Run anywhere else, each test reports that it could not find its device and
says what would provide one, rather than passing having checked nothing.
Nothing in this crate binds or unbinds a driver on a machine it does not
own.

## Status

`pci_testdev_tests` passes in full.

`edu_tests` passes 25 of 29 checks: identity, liveness across six probes,
five factorials with their completion flag, bus mastering, BAR mapping, and
raising and acknowledging an interrupt. The four that fail are the DMA
round-trip: transfers complete and the device reports back exactly the
source, destination and count it was given, but the bytes do not arrive
where expected and the IOMMU logs translation faults at addresses unrelated
to the ones programmed. That is unresolved, and it is written down here
rather than skipped, because a harness that hid its own failing check would
be worse than useless.

## Licence

MIT OR Apache-2.0.
