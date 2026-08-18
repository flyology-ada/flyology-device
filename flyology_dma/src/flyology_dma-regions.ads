private with Ada.Finalization;
with System;

--  Contiguous host memory suitable for device access.
--
--  A Region owns one mapping: its address, its length, and how it is backed.
--  It is limited and controlled, so it cannot be copied and it releases its
--  mapping when it goes out of scope.
--
--  A Region deliberately knows nothing about IOVAs. Making memory visible to
--  a device is the business of a Mapper, and the resulting binding is owned
--  by the Mapping value that Flyology_DMA.Mappers.Map_Region returns, not by
--  the Region. Keeping the two apart is what makes the teardown order right:
--  a Mapping declared after its Region finalizes first, so the device-visible
--  mapping is torn down while the memory behind it still exists.
--
--  The reverse order is the bug this arrangement exists to prevent. A region
--  whose memory is released while the IOMMU mapping still stands leaves the
--  device able to write into pages the process no longer owns, and nothing
--  reports it until something unrelated is corrupted.
package Flyology_DMA.Regions is

   --  One contiguous, page-aligned allocation of host memory.
   type Region is limited private;

   --  Creates a region of at least Length bytes.
   --
   --  The length is rounded up to a whole number of pages of the requested
   --  backing, so a region is always a whole number of pages and can always
   --  be mapped as one. The backing is never chosen for the caller and never
   --  substituted: asking for Huge_2M on a host with no hugepage pool raises
   --  rather than returning ordinary pages.
   --
   --  Lock is not the mechanism that makes a region safe for device access;
   --  see Flyology_DMA.Thin.Map_Anonymous for why it defaults to False.
   --
   --  @param Length Requested size in bytes, rounded up to whole pages
   --  @param Backing How the memory is backed
   --  @param Lock Whether to lock the pages into RAM with mlock
   --  @return The new region
   --  @exception Hugepage_Unavailable The backing is unsupported here or has
   --    no pages reserved
   --  @exception Memory_Lock_Failed Lock was requested and refused
   --  @exception Region_Error The mapping failed for another reason
   function Create
     (Length  : Byte_Count;
      Backing : Region_Backing;
      Lock    : Boolean := False) return Region
     with Pre => Length > 0;

   --  The host virtual address of the first byte of the region.
   --  @param Self The region
   --  @return Address of the first byte
   function Base_Address (Self : Region) return System.Address;

   --  The size of the region in bytes, after rounding up to whole pages.
   --  @param Self The region
   --  @return Size in bytes
   function Length (Self : Region) return Byte_Count;

   --  How the region's memory is backed.
   --  @param Self The region
   --  @return The backing chosen at creation
   function Backing (Self : Region) return Region_Backing;

   --  The size of one page of the region's backing, in bytes.
   --  @param Self The region
   --  @return Page size in bytes
   function Page_Size (Self : Region) return Byte_Count;

private

   type Region is limited new Ada.Finalization.Limited_Controlled with record
      Base   : System.Address := System.Null_Address;
      Extent : Byte_Count     := 0;
      Kind   : Region_Backing := Regular_Pages;
      Page   : Byte_Count     := 1;
   end record;

   overriding procedure Finalize (Self : in out Region);

   function Base_Address (Self : Region) return System.Address is (Self.Base);
   function Length (Self : Region) return Byte_Count is (Self.Extent);
   function Backing (Self : Region) return Region_Backing is (Self.Kind);
   function Page_Size (Self : Region) return Byte_Count is (Self.Page);

end Flyology_DMA.Regions;
