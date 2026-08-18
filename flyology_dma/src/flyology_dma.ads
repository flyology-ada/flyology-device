with System;

--  DMA-capable host memory for userspace device drivers.
--
--  This crate provides three things: contiguous, page-locked regions of host
--  memory suitable for device access; management of the address space a
--  device sees; and fixed-size buffer pools carved from those regions whose
--  handles carry both addresses a driver needs.
--
--  It contains no device knowledge of any kind. It does not know what a
--  packet is, what a descriptor is, or that VFIO exists. Establishing a
--  device-visible mapping is inherently the business of whatever kernel
--  interface owns the IOMMU, so this crate declares the abstract Mapper
--  interface in Flyology_DMA.Mappers and performs no mapping itself. The
--  flyology_vfio crate implements that interface; the dependency runs one
--  way, and other backends can take VFIO's place without the region and
--  pool code noticing.
--
--  The two address worlds this crate keeps apart are host virtual addresses,
--  which are System.Address values the CPU dereferences, and I/O virtual
--  addresses, which are IOVA_Address values a device places on the bus.
--  Confusing them is the defining bug of this problem domain: a device told
--  to write at a host virtual address will write somewhere else entirely,
--  and without an IOMMU to refuse the access it will corrupt whatever host
--  memory happens to live there. The two are therefore unrelated types with
--  no implicit conversion between them, and the one place they are related
--  is a documented per-region linear shift.
package Flyology_DMA
  with Pure
is

   --  An address as a device sees it, placed on the bus in a descriptor or a
   --  register. Distinct from System.Address, which the CPU dereferences.
   --
   --  Whether an IOVA is translated at all depends on the backend. Under an
   --  IOMMU it is translated to a physical address by page tables the mapper
   --  installed. Without an IOMMU a device consumes physical addresses
   --  directly, and only a mapper that resolves them may be used.
   type IOVA_Address is mod 2 ** 64
     with Size => 64;

   --  A length or offset in bytes.
   --
   --  The upper bound is 128 TiB rather than 2 ** 64 - 1 so that sums of
   --  lengths cannot silently wrap: an overflow is a check failure at the
   --  point of the mistake rather than a region that appears to end before
   --  it starts.
   type Byte_Count is range 0 .. 2 ** 47;

   --  A power-of-two alignment in bytes.
   --
   --  Values are constrained to powers of two by Is_Power_Of_Two, which every
   --  subprogram taking an Alignment states as a precondition. The type
   --  itself cannot carry that predicate without becoming self-referential.
   type Alignment is range 1 .. 2 ** 40;

   --  True when Value is a power of two, and so usable as an alignment.
   --  @param Value The candidate alignment
   --  @return True when exactly one bit of Value is set
   function Is_Power_Of_Two (Value : Alignment) return Boolean
     with Global => null;

   --  Rounds Value up to the next multiple of To.
   --  @param Value The value to round
   --  @param To The alignment to round to
   --  @return The smallest multiple of To that is not less than Value
   function Align_Up (Value : Byte_Count; To : Alignment) return Byte_Count
     with
       Global => null,
       Pre    =>
         Is_Power_Of_Two (To)
         and then Value <= Byte_Count'Last - Byte_Count (To) + 1,
       Post   =>
         Align_Up'Result >= Value
         and then Align_Up'Result mod Byte_Count (To) = 0
         and then Align_Up'Result - Value < Byte_Count (To);

   --  How the host memory behind a region is backed.
   --
   --  The choice is always explicit at construction. Nothing in this crate
   --  falls back from a hugepage backing to a smaller one: a driver that
   --  asked for 2 MiB pages and silently received 4 KiB pages would see the
   --  IOMMU page-table pressure it was trying to avoid, and would find out
   --  only from a performance measurement.
   --
   --  @enum Huge_2M Two-mebibyte hugepages. Linux only.
   --  @enum Huge_1G One-gibibyte hugepages. Linux only, and usually needs
   --    pages reserved on the kernel command line rather than at run time.
   --  @enum Regular_Pages Ordinary anonymous pages at the kernel's base page
   --    size. Present so the portable units can be tested on a host without
   --    reserved hugepages, and so non-DMA uses of a region are possible. It
   --    is never a default and never a fallback.
   type Region_Backing is (Huge_2M, Huge_1G, Regular_Pages);

   --  The numeric value of a host virtual address, viewed as an IOVA.
   --
   --  This is the only conversion between the two address worlds in the
   --  crate, and it is deliberately the only one: every place where a host
   --  address becomes something a device might consume is a call to this
   --  function, so the whole set of them is one grep away.
   --
   --  Using the result as a real IOVA is meaningful in exactly one case: an
   --  IOMMU that has been deliberately programmed with identity mappings, so
   --  that the address the device emits translates back to the same host
   --  page. It is meaningless without an IOMMU, where a device consumes
   --  physical addresses and a host virtual address is a wild pointer into
   --  whatever physical memory happens to answer.
   --
   --  @param Host A host virtual address
   --  @return The same bit pattern viewed as an IOVA
   function Mirrored (Host : System.Address) return IOVA_Address
     with Global => null;

   --  Raised when a hugepage-backed region cannot be obtained.
   --
   --  The message names which of the two distinguishable conditions applies:
   --  a kernel built without hugetlbfs, or a kernel with hugetlbfs but no
   --  pages of the requested size reserved. Both are host configuration, and
   --  the message carries the command that changes it.
   Hugepage_Unavailable : exception;

   --  Raised when a region's pages cannot be locked into RAM.
   --
   --  Almost always RLIMIT_MEMLOCK. The message carries the current limit and
   --  the amount the failed request needed.
   Memory_Lock_Failed : exception;

   --  Raised when a region cannot be created or released for a reason that is
   --  neither of the two above. The message carries the failing operation and
   --  its errno.
   Region_Error : exception;

   --  Raised when an IOVA allocation cannot be satisfied from the window it
   --  was asked of. The message carries the window and the failed request.
   IOVA_Exhausted : exception;

   --  Raised when a mapper cannot establish or remove a device-visible
   --  mapping. The message names the specific failed condition.
   Mapping_Error : exception;

   --  Raised when a pool is used outside its contract: a buffer released
   --  twice, a handle returned to a pool it did not come from, or a pool
   --  built over a region too small for the geometry asked of it.
   Pool_Error : exception;

end Flyology_DMA;
