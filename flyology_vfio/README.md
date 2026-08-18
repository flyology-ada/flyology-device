# flyology_vfio

The Linux VFIO userspace device interface for Ada: container, group and
device lifecycle, PCI BAR mapping, MMIO register access with the ordering
already decided, IOMMU mapping, and interrupt delivery.

This crate is experimental. It has been exercised against emulated devices
in a virtual machine and has never touched real hardware.

## What it does, and where it stops

VFIO lets a userspace process own a PCI device. This crate binds that
interface and nothing beyond it: what it hands back is a mapped BAR, a
working DMA mapping, and an interrupt. There is no driver here, no
descriptor format, and no packet — a virtio or ixgbe identifier anywhere in
`src/` would mean the boundary had been breached.

It implements the `Mapper` that [`flyology_dma`](../flyology_dma/) declares,
which is what closes the loop: that crate owns hugepage memory and knows
nothing about VFIO, and this one knows how to make that memory visible to a
device.

## The three descriptors, and why they are different types

| Type | Opened from | What it is |
| --- | --- | --- |
| `Container_FD` | `/dev/vfio/vfio` | An address space a device can be given access to. DMA mappings are made against it |
| `Group_FD` | `/dev/vfio/<n>` | The smallest set of devices the IOMMU can isolate. Whole groups are assigned, never single devices |
| `Device_FD` | a group | The device itself |

They are distinct types because six VFIO request numbers mean one thing on a
container and something entirely different on a device — `VFIO_IOMMU_MAP_DMA`
and `VFIO_DEVICE_PCI_HOT_RESET` are the same number, and there are five more
pairs. Nothing in the number says which was meant, so the distinction lives
where the compiler can enforce it.

## The ordering that fails silently

Four things must happen in order, and each one the kernel refuses with a bare
`EINVAL` that names nothing. All four are preconditions rather than comments:

1. A group is attached to a container **before** `Set_IOMMU`.
2. `Set_IOMMU` succeeds **before** a device descriptor can be obtained.
3. Both **before** any memory can be mapped.
4. The group must report itself viable, which means every device in its IOMMU
   group is bound to `vfio-pci` or to nothing. One stray device still held by
   a kernel driver blocks the whole group.

And one that no precondition can express:

> **Bus mastering is not enabled for you.** VFIO leaves the PCI command
> register alone. A device can be opened, mapped and programmed, and will
> still never issue a single DMA until `Config_Space.Enable_Bus_Mastering`
> is called. This is the most common way the whole exercise fails, and the
> symptom is nothing happening rather than an error.

## Packages

| Package | What it holds |
| --- | --- |
| `Flyology_VFIO` | The three descriptor types and the crate's exceptions |
| `Flyology_VFIO.Thin` | Argument struct layouts, pinned by representation clauses |
| `Flyology_VFIO.Thin.Constants` | Generated from the kernel headers; never hand-written |
| `Flyology_VFIO.Thin.Layout` | Compile-time assertions that the layouts match C |
| `Flyology_VFIO.Thin.Syscalls` | The three shapes a VFIO ioctl comes in, and the other calls |
| `Flyology_VFIO.Containers` | Open, check the API and IOMMU, set the IOMMU |
| `Flyology_VFIO.Groups` | Open, check viability, attach and detach |
| `Flyology_VFIO.Devices` | Obtain a device by PCI address; region and interrupt counts |
| `Flyology_VFIO.Regions` | Describe regions and map one into the process |
| `Flyology_VFIO.Config_Space` | Read and write configuration space; enable bus mastering |
| `Flyology_VFIO.Registers` | MMIO access, with barriers |
| `Flyology_VFIO.DMA_Mapper` | The concrete `Mapper` over a container |
| `Flyology_VFIO.Interrupts` | eventfd delivery, masking, and MSI-X |

## Where the numbers come from

Every ioctl number, flag, struct size and field offset is generated from the
kernel headers of a Linux host by `scripts/generate-constants.sh`, which
compiles a C program that prints them with `sizeof` and `offsetof`. On a host
with no Linux headers it regenerates inside the repository's container, so the
output is the same wherever it is run.

`scripts/verify-constants.sh` regenerates and diffs, and the test suite runs
it. Drift between the committed numbers and the kernel is a test failure
rather than an `EINVAL` somewhere far away later.

The Ada representation clauses are checked against those sizes and offsets at
compile time by `Flyology_VFIO.Thin.Layout`, using `'Object_Size` rather than
`'Size` — GNAT's `'Size` excludes trailing padding where C's `sizeof`
includes it, and for these structs the two differ.

## MMIO ordering

Ordering is this crate's responsibility, not the caller's, so the primitives
come in ordered pairs and the memory model is part of the name:
`Write_Release_32` for a doorbell, `Read_Acquire_32` for a completion flag,
plus standalone `Store_Fence`, `Load_Fence` and `Full_Fence`.

Ada's own `Atomic` is not used for this: Ada 2022 requires atomic objects to
be sequentially consistent with no way to ask for acquire or release, which
is both stronger than a doorbell needs and the wrong shape. The ordered
accessors are built on the compiler's atomic builtins with the memory model
fixed at each call site — never a parameter, because GCC silently falls back
to the strongest ordering when the model is not a compile-time constant.

Plain accesses use `Volatile_Full_Access`, which guarantees a single
whole-object load or store. Note the hazard it does not remove: assigning to
part of a register performs a hidden full-width read first, which is wrong on
a register that clears bits on read or on writing a one. For those, write the
whole value the specification calls for.

vfio-pci maps device regions uncacheable and offers no write-combining
mapping, so no code path here can obtain one.

## Waiting for an interrupt

VFIO reduces an interrupt to a readable descriptor, which leaves one
question the crate cannot answer for you: what a program does while it
waits. The three reasonable answers are incompatible, and all three are
legitimate.

A poll-mode driver never waits at all — it reads a completion queue in a
loop and takes no interrupt on the data path, which costs a core and buys
the lowest latency available. A program with an event loop wants to suspend
one task and let the others run. A program with neither wants to block.

So `Interrupts.Waiter` is declared rather than fixed, for the same reason
`Flyology_DMA.Mappers.Mapper` is: the answer belongs to the caller.
`Blocking_Waiter` ships with the crate for programs that have no event loop,
and is deliberately a duplicate of what `Flyology.IO.Wait` already does
better — see `flyology_vfio_runtime` for the adapter that uses it. That
adapter also carries one deadline across `EINTR` retries, which
`Blocking_Waiter` does not.

`Wait_For_Any` takes several descriptors and returns the lowest ready
index, which is what a driver with one vector per queue needs.

## Interrupts that arrive exactly once

A legacy pin interrupt is *automasked*: the kernel masks it the moment it
fires and leaves it masked, because a shared line it cannot quiet would
re-assert forever. A handler that acknowledges the device but never calls
`Interrupts.Unmask` therefore receives one interrupt and then silence, with
nothing reporting the omission. `Interrupts.Describe` says which indices
behave this way.

## Building and testing

```sh
cd flyology_vfio && alr build
./scripts/test.sh
./scripts/host-readiness.sh
```

Everything builds on Linux and on macOS. On macOS the crate compiles, links
and runs — the platform body reports that VFIO and `eventfd` do not exist
there — so the binding-level tests are meaningful on a development host.

The tests that need a real device live in
[`flyology_vfio_qemu`](../flyology_vfio_qemu/), which drives QEMU's virtual
PCI devices in a virtual machine with an emulated IOMMU. `showcases/bring_up`
walks any device through the whole lifecycle:

```sh
./showcases/bin/bring_up 0000:00:02.0
```

Nothing in this crate binds or unbinds a driver. A device must already be
bound to `vfio-pci`, which is a decision for whoever owns the machine —
unbinding the wrong device takes the machine down.

## Licence

MIT OR Apache-2.0.
