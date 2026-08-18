# flyology-device

Userspace device access for Ada: the memory a device can reach, and the
kernel interface that lets it reach it.

Both crates here are experimental. Neither has driven real hardware.

| Crate | What it does |
| --- | --- |
| [`flyology_dma`](flyology_dma/) | Hugepage-backed regions, IOVA management, and buffer pools whose handles carry both the host and device addresses of the same bytes |
| [`flyology_vfio`](flyology_vfio/) | The Linux VFIO userspace interface: container, group and device lifecycle, BAR mapping, MMIO access, and the `Mapper` implementation that closes the loop with `flyology_dma` |
| [`flyology_vfio_qemu`](flyology_vfio_qemu/) | A bring-up harness driving QEMU's virtual PCI devices through the other two, so that they are tested against a device rather than only against the kernel's refusals |

The repository root is not a crate. Each crate is a peer with its own
manifest, project file, tests, and scripts, and is released independently.

## Why two crates

Establishing an I/O virtual address is an ioctl on a VFIO container, so
mapping is inherently a VFIO operation. Rather than make the memory crate
depend on the kernel-interface crate, `flyology_dma` declares an abstract
`Mapper` and performs no mapping itself; `flyology_vfio` implements it. The
dependency runs one way, `flyology_vfio -> flyology_dma`, and there is no
cycle.

That is what lets other backends — a no-IOMMU backend that resolves physical
addresses, a platform-bus backend, a test mapper — take VFIO's place without
the region and pool code noticing.

## What is deliberately absent

No driver, no descriptor format, no packet — in the two lower crates.
`flyology_vfio` gets you a mapped BAR, a working DMA mapping, and an
interrupt, and stops. A generic descriptor ring designed before any real
device existed would have been wrong, so there isn't one; the rings that
exist live in `flyology_vfio_qemu`, shaped by the devices that needed them.

That crate is where device knowledge is allowed and the only place it is.
It is a peer rather than a layer, and nothing depends on it: it exists so
that the two below it are tested against a device that follows the
addresses they hand out, which is the one thing neither can establish about
itself.

## Getting started

```sh
./scripts/test.sh          # every crate's tests
./scripts/prove.sh         # every crate's proofs
./scripts/docs.sh          # every crate's API documentation
```

Each crate has the same three scripts of its own, plus whatever else it
needs; the root scripts only dispatch.

## Platforms

Both crates target Linux. `flyology_dma` calls `mmap` with `MAP_HUGETLB`;
`flyology_vfio` calls `ioctl` on `/dev/vfio`. macOS is supported as a
development host for the portable units only.

Three environments matter, and it is worth being explicit about what each can
actually check:

| Environment | Provisioned by | Can check | Cannot check |
| --- | --- | --- | --- |
| Container | [`scripts/linux/run.sh`](scripts/linux/run.sh) | Both crates build; every test needing only ordinary memory; ioctl constants against the kernel headers | Hugepages — container kernels are built without `hugetlbfs`; anything needing an IOMMU |
| Virtual machine | [`scripts/qemu/`](scripts/qemu/) | Hugepage regions with real 2 MiB and 1 GiB pages; VFIO against an emulated IOMMU | Real device behaviour, timing, errata |
| Bare metal | you | Everything | — |

A result is only ever reported alongside the environment that produced it. A
passing test in a container says nothing about hugepages.

## Licence

MIT OR Apache-2.0, at your option. See [LICENSE-MIT](LICENSE-MIT) and
[LICENSE-APACHE](LICENSE-APACHE).
