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
| `edu` ×2 | `1234:11e8` | BAR mapping, MMIO of every width, ordered accesses, a computation with a completion flag, a DMA engine that follows an IOVA, interrupt delivery over eventfd. Two of them, in separate IOMMU groups, so a container holding more than one group can be tested |
| `pci-testdev` | `1b36:0005` | An MMIO BAR and, usefully, an I/O port region VFIO reports as unmappable, so the refusal path meets a real kernel refusal |
| `nvme` | `1b36:0010` | A 64-bit BAR, 64-bit registers, a doorbell at a stride the device itself reports, eight MSI-X vectors, a region carrying a capability chain, and a controller that reaches memory by DMA through three separately programmed addresses |
| `e1000e` | `8086:10d3` | Four regions on one device — MMIO, flash, an unmappable I/O window, and an MSI-X region with a capability chain — five MSI-X vectors, and a reset the device completes itself |

`ivshmem` would have been another. QEMU 10.2 has no ivshmem device at all —
it was deprecated upstream and dropped. The crate is arranged so another
device is a new child package and a new test program, nothing more.

## Corpora

Two of the tests check values chosen outside the program, which is worth
more than any self-consistency check: a register window reading plausible
rubbish fails them, and a mistake that happens to be internally consistent
cannot pass.

- The NVMe controller's **serial number** is set on the command line that
  starts the guest, and arrives here inside four kibibytes the controller
  wrote by DMA into memory the IOMMU was programmed for. Every address in
  that path has to be right for the string to appear.
- The Intel controller's **MAC address** is likewise set on the command
  line, and is read straight back out of its receive address registers.

Both are passed into the guest by `scripts/qemu/test.sh` rather than
hard-coded in the tests, so the harness and the tests cannot disagree about
what the expected value is.

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

## What it has already caught

Three bugs, none of which reported itself, and each of a kind that would
have been extremely hard to find against real hardware.

**An IOVA wider than the IOMMU.** 2⁴⁶ was accepted by
`VFIO_IOMMU_MAP_DMA` and then refused by an IOMMU advertising a 44-bit
input address size.

**An IOVA wider than the device.** `edu` masks bus addresses to its
`dma_mask`, twenty-eight bits by default, and issues the transfer against
the truncated result rather than complaining. An address of four gibibytes
became zero. Every layer reported success and no bytes moved. On a machine
with no IOMMU to refuse the truncated address, it would instead have
written to whatever physical memory sat at the masked address.

`Edu.Transfer` now refuses an address that does not fit rather than letting
it be masked, which is the general lesson: an IOVA has to satisfy the
IOMMU's input width, the device's DMA width, and the ranges the platform
reserves, and nothing checks them for you.

**A missing unmask.** A legacy pin interrupt is automasked: VFIO masks it on
delivery and leaves it masked, because it cannot know when userspace has
quieted a shared line. A handler that acknowledges the device but never
re-arms the line receives exactly one interrupt and then silence, with no
error anywhere. `flyology_vfio` had no unmask operation at all; it now has
`Flyology_VFIO.Interrupts.Unmask`, and this crate is what found the gap.

## Status

All five suites pass in the repository's virtual machine against an
emulated SMMUv3: `edu_tests` at 29 checks, `container_sharing_tests` at 18,
`pci_testdev_tests` at 10, `nvme_tests` at 20, and `e1000e_tests` at 15.

## Licence

MIT OR Apache-2.0.
