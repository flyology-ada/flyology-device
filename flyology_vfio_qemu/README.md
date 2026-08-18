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
| `nvme` | `1b36:0010` | A 64-bit BAR, 64-bit registers, a doorbell at a stride the device reports itself, eight MSI-X vectors, a region carrying a capability chain — and a controller driven far enough to create I/O queues and write and read actual blocks |
| `e1000e` | `8086:10d3` | Four regions on one device — MMIO, flash, an unmappable I/O window, and an MSI-X region with a capability chain — five MSI-X vectors, a reset the device completes itself, and descriptor rings carrying a real frame out and a real reply back |

`ivshmem` would have been another. QEMU 10.2 has no ivshmem device at all —
it was deprecated upstream and dropped. The crate is arranged so another
device is a new child package and a new test program, nothing more.

## What the devices are actually made to do

The two larger devices are driven to the point of doing their job, because
a device that only answers register reads exercises far less than one doing
real work. Everything below is memory the device reaches by DMA through
addresses this code programmed into the IOMMU.

**The NVMe controller is brought up and used as a disk**, on the
arrangement a driver would actually use: four queue pairs, each bound to
its own MSI-X vector, with completions collected by waiting rather than
spinning. Work is submitted to every queue before any is collected, which
is the part a one-queue-at-a-time test never reaches. It is disabled,
its admin queues are pointed at mapped memory, and it is enabled — at which
point it reads its submission queue, writes its completion queue and writes
four kibibytes of Identify data, all by DMA. Then it is asked to describe
its namespace, an I/O queue pair is created, and blocks are written and read
back:

- a buffer written to block zero and read back byte for byte;
- a different pattern written at a later block, read back, and block zero
  re-read to confirm the second write went where it was told;
- a read past the end of the namespace, which must be refused with a status
  rather than quietly accepted;
- the queue pair removed again, submission queue first, because a
  completion queue still serving one cannot be deleted;
- a shutdown notification, which is a different thing from disabling the
  controller: it tells it to commit what it is holding, and reports its
  progress in a status field of its own.

A second, zoned namespace carries the zone commands: zones are reported,
emptied, appended to — the controller choosing where the data lands and
saying so afterwards, which is the property the command set exists for —
finished, refused further appends once full, and reset. A third namespace
is detached and reattached at run time, with the active namespace list
confirming it.

Its feature surface is read four ways rather than one — current, default,
saved, and which of those the feature supports — because a driver reading
only the current value cannot tell a controller that ignored a Set from one
that accepted it and reset.

**The Intel controller is brought up and used as a network interface.**
Receive and transmit descriptor rings are built in mapped memory, the rings
are handed to the device, the link is brought up, and an address resolution
request for the gateway is transmitted. QEMU's user networking answers it,
and the reply is checked: that it is a reply rather than a request, that it
is addressed to the hardware address the device reported, and that it
answers for the address that was asked about.

A second frame is then sent in loopback, where the device routes it
straight back into its own receive path. That proves both rings without
anything attached, which the exchange above cannot: that one depends on
something outside the guest choosing to answer.

The interrupt cause register is provoked and read twice, showing that
reading it is what acknowledges it — the sharpest example of why a status
register must never be read-modify-written, since there the read is the
acknowledgement. Finally the counters are read: frames and octets in both
directions, broadcasts, checksum errors and misses, each clearing as it is
read.

## Measuring coverage instead of claiming it

Deciding what to test by reading a device's source has an obvious failure
mode: the reading is done once, by hand, against whatever version was
current, and nothing notices when it stops being true. Two programs ask the
devices instead.

`nvme_coverage_tests` issues every opcode, feature identifier and log
identifier in turn and reports what came back. It can tell an unimplemented
command from an implemented one because the two produce different status
codes — Invalid Command Opcode means absent, anything else means present
and unhappy with its arguments. `e1000e_coverage_tests` does the equivalent
for the register window, the physical-layer chip behind it, and the
non-volatile configuration memory.

Both then compare that measured surface against the list of things the
functional tests drive, and **fail if coverage falls below a recorded
floor**. That is what makes them tests rather than documents: coverage that
decays silently is the thing being guarded against.

What they currently report:

| Surface | Implemented | Exercised |
| --- | --- | --- |
| NVMe admin commands | 13 of 25 probed (7 more deliberately not probed) | 13 |
| NVMe namespace commands | 15 of 15 probed | 12 |
| NVMe features | 12 of 32 answer without a namespace | 3 driven, 2 round-tripped |
| NVMe logs | 5 of 16 | 3 |
| e1000e registers | 42 of 42 probed answer | 34 |
| e1000e physical-layer registers | 23 of 32 | 3 |

## What the emulated devices do not implement

The probes exist to find this out, and what they found is worth writing
down. All of it is about QEMU, not about the specifications.

**The NVMe controller has no** Namespace Management, Device Self-test, Keep
Alive, Virtualization Management or Get LBA Status. It does implement
Namespace Attachment, Directive Send and Receive, Doorbell Buffer Config and
Abort, none of which the functional tests drive yet.

**It reports every namespace opcode as implemented**, including Zone Append
and the zone management commands, on a namespace that is not zoned. That is
a property of how the command-set table is built rather than a claim the
commands would work, and it is why the probe counts what is *present* rather
than what would *succeed*.

**Arbitration is refused.** Feature `0x00` appears in QEMU's own support
table and is nonetheless answered with Invalid Field in Command. Features
answered are `0x01`, `0x02`, `0x04`, `0x06` through `0x0B`, `0x0E`, `0x16`
and `0x19`.

**Error Recovery needs a namespace and the others must not have one.** A
controller-scope feature named with a namespace identifier is refused, and a
per-namespace feature without one likewise. Both refusals are correct and
both are easy to read as the controller being wrong.

**A filesystem's view and the driver's view of one namespace agree.** A
file written through an ordinary file interface is found on the medium by
this driver, reading blocks and looking for the bytes rather than parsing
any filesystem; the driver writes different bytes over them, and the file
then reads back as what the driver wrote. The namespace is handed between
the kernel and vfio-pci between turns rather than shared, because a disk
has one owner at a time.

The filesystem is made fresh each run and is the one the base guest image
can already make. A harness that needs a package installed first works on
the machine it was written on and nowhere else, and a filesystem kept
between runs accumulates the leavings of all of them.

**A block device's name is not its namespace identifier.** Namespace three
starts detached, so it takes an identifier and no name, and namespace four
arrives as `nvme0n3` — until it does not. The harness selects by reading
each device's `nsid`.

**Transfers longer than two pages need a page list, and nothing chains
them.** One list page names five hundred and twelve pages, so a single
command here moves at most two mebibytes however large the controller says
its own limit is. A transfer needing a chained list is refused rather than
described wrongly.

**Segmentation offload works, and is the one thing here a loopback could
never have checked.** The device is handed one buffer of four thousand
bytes with a single template header and emits as many frames as that takes,
advancing the sequence number and recomputing both checksums for each. All
four thousand bytes arrive in a socket. A driver that miscounts the header
length produces frames that are individually well formed and collectively
nonsense, and nothing on the sending side notices.

**Receive-side scaling and receive checksum offload are mutually
exclusive.** The hash goes in the four descriptor bytes the checksum would
occupy, so the device reports one or the other. Scaling therefore requires
the packet checksum to be switched *off* and the longer descriptor layout
to be switched on, neither of which reads like a prerequisite for hashing.
Leave either alone and every frame lands on the first queue, with the
redirection table reading back exactly as written.

**Nothing is hashed on the loopback path.** The device steers frames that
arrive from outside and sends frames it transmitted to itself straight to
the first queue, so scaling cannot be observed without a peer on the wire.

**The redirection table's queue is bit seven of each byte.** Not bit zero,
which is where a reader who knows the field is one bit wide will put it,
and which yields a table that reads back exactly as written and steers
nothing.

**The coverage probe leaves the controller writing into host memory.**
Probing Doorbell Buffer Config tells the controller where to keep a copy of
its doorbells, and it writes there after every ring from then on. The
memory goes away at the end of the test and the controller does not, so the
guest logs a burst of IOMMU translation faults. They are the IOMMU doing
its job and no result depends on them, but a probe that changes the device
rather than asking it a question is worth knowing about.

**A hash match is indistinguishable from an exact one.** The receive
descriptor's passed-inexact-filter bit is never set: a frame that reached
the host through the multicast hash carries the same status byte as one
addressed to the device outright. A real driver relies on that bit to know
it must check the address itself, because the hash has four thousand and
ninety-six buckets for every multicast address there is and therefore
collides. Here it cannot know.

**Only the identify directive exists.** A controller must have the
directive that describes the other directives, and QEMU's has nothing else
to describe: streams are not implemented, so there is no directive that can
be switched on and the Send that would switch one on has nothing to do. The
command is exercised only as far as the device allows.

**Reservations cannot be reached at all.** The three reservation commands
appear in QEMU's command-set table and its NVMe device offers no option
under which they work — there is no `reservations=` on either the
controller or a namespace. They are the one part of the command set here
that is unreachable rather than merely unwritten.

**A zoned namespace needs asking for twice.** The zone commands exist only
on a namespace configured for them *and* only when the controller was
enabled with every I/O command set selected rather than the basic one. Miss
the second and every zoned command answers Invalid Command Opcode, which
is indistinguishable from a controller that does not implement them.

**Write Uncorrectable is advertised and refused.** The probe sees it
answered with something other than Invalid Command Opcode, so it counts as
present, and the functional test then finds the namespace will not accept
it. Both are true: QEMU's command-set table lists it and this namespace's
configuration does not support it. The functional test skips that path by
name rather than pretending, which is the distinction the probe cannot draw
on its own — it counts what is present, not what would succeed.

**The e1000e answers every register probed**, which makes "does it answer"
a weak signal on this device: QEMU marks a number of them internally as
partial implementations that store a written value and give it back.
Its source records timestamp processing, SNAP, and iSCSI and NFS filtering
as unimplemented.

**Its interrupt mask registers cannot be read back**, one setting bits and
the other clearing them, so the only thing checkable about them is that
they accept a write. The cause register can be read, and reading it is what
acknowledges it — which the test demonstrates by reading twice.

## Corpora chosen outside the program

Some checks compare against values this program cannot have invented, which
is worth more than any self-consistency check: a register window reading
plausible rubbish fails them, and a mistake that is merely internally
consistent cannot pass.

- The NVMe controller's **serial number** is set on the command line that
  starts the guest, and arrives here inside four kibibytes the controller
  wrote by DMA. Every address in that path has to be right for the string
  to appear.
- The Intel controller's **MAC address** is likewise set on the command
  line, is read back out of the receive address registers, and appears
  again as the destination of a reply produced by a network stack outside
  the guest.

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

All seven suites pass in the repository's virtual machine against an
emulated SMMUv3: `edu_tests` at 29 checks, `container_sharing_tests` at 18,
`pci_testdev_tests` at 10, `nvme_tests` at 67, `e1000e_tests` at 40,
`nvme_coverage_tests` at 11 and `e1000e_coverage_tests` at 7.

## Licence

MIT OR Apache-2.0.
