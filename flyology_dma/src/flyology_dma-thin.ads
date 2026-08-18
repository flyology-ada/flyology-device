with System;

--  The host memory syscalls this crate needs, and nothing else.
--
--  This package exists so that the platform-dependent surface is one small,
--  auditable unit rather than a scattering of imports. Its specification is
--  portable; its body is supplied per platform from src/linux or src/darwin,
--  selected by the FLYOLOGY_DMA_PLATFORM external in the project file.
--
--  Failures are raised as the exceptions declared in Flyology_DMA rather
--  than returned, and every message names the specific condition and the
--  command that would change it. The failure modes in this domain are
--  environmental, and an error that says only "mmap failed" costs an hour.
package Flyology_DMA.Thin is

   --  Reports whether this platform can back a region the given way.
   --
   --  Darwin supports Regular_Pages only. Asking for a hugepage backing
   --  there raises Hugepage_Unavailable rather than quietly returning
   --  ordinary pages.
   --  @param Backing The backing to test
   --  @return True when Map_Anonymous can satisfy this backing here
   function Supports (Backing : Region_Backing) return Boolean;

   --  The size of one page of the given backing, in bytes.
   --
   --  Defined for every backing, supported here or not: a 2 MiB hugepage is
   --  2 MiB whether or not this kernel has a pool of them. Callers round
   --  lengths with this before asking whether the backing is available, so
   --  that an unsupported backing produces the diagnostic from
   --  Map_Anonymous rather than a failed precondition here.
   --
   --  @param Backing The backing to report on
   --  @return The page size in bytes
   function Page_Size (Backing : Region_Backing) return Byte_Count
     with Post => Page_Size'Result > 0;

   --  Maps anonymous memory suitable for device access.
   --
   --  Length must be a whole multiple of the backing's page size; a caller
   --  that rounds with Align_Up satisfies this. The mapping is eagerly
   --  populated, so a shortage of pages fails here rather than at the first
   --  device write, and MAP_NORESERVE is never used.
   --
   --  Locking with mlock is offered but is not what makes a region safe for
   --  DMA, and it is not the default. Residency is not a stable physical
   --  address: locked pages can still be migrated by compaction. The pin
   --  that matters is taken by the mapper when the region is mapped into
   --  the IOMMU, and it is that pin, not mlock, which the device relies on.
   --  Worse, mlock and a VFIO mapping both charge the same RLIMIT_MEMLOCK
   --  budget, so locking a region that is about to be mapped halves the
   --  memory the process can actually use. Lock regions that no device will
   --  map; leave the rest to the mapper.
   --
   --  @param Length Size of the mapping in bytes
   --  @param Backing How the mapping is backed
   --  @param Lock Whether to also lock the pages into RAM with mlock
   --  @return Base address of the new mapping
   --  @exception Hugepage_Unavailable A hugepage backing is unsupported here
   --    or has no pages reserved
   --  @exception Memory_Lock_Failed Lock was requested and the pages could
   --    not be locked, usually RLIMIT_MEMLOCK
   --  @exception Region_Error The mapping failed for another reason
   function Map_Anonymous
     (Length  : Byte_Count;
      Backing : Region_Backing;
      Lock    : Boolean) return System.Address
     with Pre => Length > 0;

   --  Releases a mapping previously returned by Map_Anonymous.
   --
   --  Base and Length must be exactly those of the original mapping. This
   --  crate never unmaps part of a region, because a partially unmapped
   --  region whose IOMMU mapping still stands is precisely the state that
   --  lets a device write into memory the process no longer owns.
   --
   --  @param Base Base address of the mapping
   --  @param Length Size of the mapping in bytes
   --  @exception Region_Error The unmapping failed
   procedure Unmap (Base : System.Address; Length : Byte_Count)
     with Pre => Length > 0;

   --  The process limit on locked memory, in bytes.
   --  @return The soft RLIMIT_MEMLOCK, or Byte_Count'Last when unlimited
   function Memory_Lock_Limit return Byte_Count;

   --  Why this platform cannot back a region the given way, and what would
   --  change it.
   --
   --  Empty when the backing is supported. Platform-specific, because the
   --  advice is: a Linux host without hugetlbfs needs a different kernel,
   --  and Darwin needs a different operating system.
   --
   --  @param Backing The backing to explain
   --  @return A sentence naming the condition and its fix, or the empty
   --    string when there is nothing to explain
   function Unsupported_Reason (Backing : Region_Backing) return String;

   --  The number of free pages of the given hugepage backing the kernel
   --  reports. Zero on a platform or backing with no such notion.
   --  @param Backing The backing to report on
   --  @return Count of pages currently free for this backing
   function Hugepages_Free (Backing : Region_Backing) return Natural;

   --  The number of pages of the given hugepage backing the kernel has
   --  reserved in total. Zero on a platform or backing with no such notion.
   --  @param Backing The backing to report on
   --  @return Count of pages reserved for this backing
   function Hugepages_Total (Backing : Region_Backing) return Natural;

end Flyology_DMA.Thin;
