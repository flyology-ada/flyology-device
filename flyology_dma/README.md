# flyology_dma

DMA-capable host memory for userspace device drivers written in Ada:
hugepage-backed regions, I/O virtual address management, and fixed-size
buffer pools whose handles carry both the host address and the
device-visible address of the same bytes.

This crate is experimental. It has been exercised on Linux and on a
development host, and it has never driven real hardware.

## What it is for

A userspace driver needs memory that a device can reach. That means memory
that stays where it is, that the device has been given permission to touch,
and that the driver can name in two different ways at once: by the host
virtual address it writes through, and by the I/O virtual address it puts in
a descriptor for the device to follow.

Those two addresses are numerically unrelated, and writing one where the
other belongs is the defining bug of this problem domain. A device handed a
host virtual address writes somewhere else entirely, and without an IOMMU to
refuse the access it corrupts whatever host memory happens to live there.
Everything in this crate is arranged around keeping them apart:
`IOVA_Address` and `System.Address` are unrelated types, the one conversion
between them is a single named function, and the pool handle carries both so
that a driver never has to pair them by hand.

## What it is not

It contains no device knowledge whatsoever: no packets, no descriptors, no
rings, and no awareness that VFIO exists. Establishing an IOVA mapping is
inherently the business of whatever kernel interface owns the IOMMU, so this
crate declares an abstract `Mapper` and performs no mapping itself. The
sibling `flyology_vfio` crate implements it. The dependency runs one way.

Descriptor rings are deliberately absent. They are device-shaped, and a
generic ring designed before any real device exists would be wrong.

## Packages

| Package | What it holds |
| --- | --- |
| `Flyology_DMA` | Core types: `IOVA_Address`, `Byte_Count`, `Alignment`, `Region_Backing`, and the crate's exceptions |
| `Flyology_DMA.Thin` | The host memory syscalls, with one body per platform |
| `Flyology_DMA.Regions` | A contiguous allocation that releases itself |
| `Flyology_DMA.Mappers` | The abstract `Mapper`, the `Mapping` that owns one binding, and a recording test mapper |
| `Flyology_DMA.Address_Space` | Choosing IOVAs, by an explicitly selected strategy |
| `Flyology_DMA.Free_Lists` | The slot bookkeeping behind a pool, written for proof |
| `Flyology_DMA.Pools` | Fixed-size buffers, each named by both of its addresses |
| `Flyology_DMA.Environment` | What the host can currently support, reported and never changed |

## Using it

```ada
--  A region, an IOVA for it, a mapping, and buffers cut from that mapping.
--  The declaration order is the teardown order reversed, which is what
--  makes the device-visible mapping go away before the memory behind it.

Space   : Address_Space.Allocator;
Backend : aliased Some_Mapper;          --  flyology_vfio supplies a real one
...
Address_Space.Configure_Window (Space, 16#4000_0000_0000#, 64 * MiB, 4096);

declare
   Area : constant Regions.Region := Regions.Create (2 * MiB, Huge_2M);
   Where : IOVA_Address;
   Fits  : Boolean;
begin
   Address_Space.Allocate
     (Space, Regions.Length (Area), 4096,
      Mirrored (Regions.Base_Address (Area)), Where, Fits);

   declare
      Bound : constant Mappers.Mapping :=
        Mappers.Map_Region (Backend'Access, Area, Where, Mappers.Device_Writes);
      Buffers : Pools.Pool (256);
      Handle  : Pools.Buffer_Handle;
      Taken   : Boolean;
   begin
      Pools.Configure (Buffers, Bound, 2048);
      Pools.Acquire (Buffers, Handle, Taken);
      --  Handle.Host goes in a memcpy. Handle.IOVA goes in a descriptor.
   end;
end;
```

`showcases/src/region_walkthrough.adb` is this program, complete and
runnable.

## Contracts worth knowing

- **Backings are never substituted.** Asking for `Huge_2M` on a host with no
  hugepage pool raises `Hugepage_Unavailable` with a message naming the
  condition and the command that changes it. It does not quietly return 4 KiB
  pages, because a driver that asked for hugepages and got small ones finds
  out from a performance measurement rather than an error.
- **Pools have a single mutator.** Two tasks calling `Acquire` concurrently
  will be handed the same buffer. This is stated rather than defended
  against; a cross-task pool is a different type, to be written when a driver
  needs one.
- **Locking is not what makes memory safe for DMA.** `mlock` guarantees
  residency, not a stable physical address, and the pin that matters is taken
  by the mapper. Regions are not locked by default, and locking one that is
  about to be mapped charges `RLIMIT_MEMLOCK` twice.
- **`Identity_Mapper` is a test mapper, not a no-IOMMU backend.** Without an
  IOMMU a device consumes physical addresses; handing it host virtual
  addresses would scatter writes across arbitrary physical memory. A real
  no-IOMMU backend resolves host pages to physical addresses and is a
  different implementation.

## Building and testing

```sh
cd flyology_dma && alr build
./scripts/test.sh
./scripts/host-readiness.sh
```

Everything builds and every test runs on Linux and on macOS. On macOS the
hugepage backings are unavailable, and the tests assert that the failure says
so rather than falling back; the Darwin platform body exists for development,
not as a target.

Hugepage paths need a Linux kernel with `hugetlbfs` and pages reserved.
Container kernels usually have neither: see `scripts/linux/` and
`scripts/qemu/` in the repository root for the two Linux environments this
repository provisions, and what each of them can actually check.

## Proof

`./scripts/prove.sh` proves `Flyology_DMA.Free_Lists` and
`Flyology_DMA.Address_Space`. Those two are where an off-by-one corrupts host
memory without anything reporting it: one hands out buffer slots, the other
hands out addresses a device will follow. The rest of the crate is outside
SPARK — controlled types over syscalls — and is not claimed to be proved.

## Licence

MIT OR Apache-2.0.
