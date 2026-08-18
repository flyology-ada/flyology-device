private with Ada.Finalization;
with Flyology_DMA;
with Interfaces;
with System;

--  The regions a device exposes, and mapping one into the process.
--
--  For a PCI device the regions are its six base address registers, its
--  expansion ROM, and its configuration space. Which of them can be mapped
--  is the device's business, not this crate's: configuration space never
--  can, an I/O port BAR never can, and a BAR smaller than a page may not.
--  Map refuses a region the kernel did not mark mappable rather than letting
--  mmap fail with something less specific.
--
--  A region's Offset is a position within the device file descriptor, which
--  is what mmap, pread and pwrite use. It is not a physical address and has
--  nothing to do with where the BAR sits on the bus.
package Flyology_VFIO.Regions is

   --  Which region of a device. Index 0 is BAR0 for a PCI device.
   type Region_Index is range 0 .. 63;

   --  What the kernel reports about one region.
   --
   --  @field Index Which region this describes
   --  @field Implemented Whether the device has this region at all. A PCI
   --    device reports nine regions whether or not it has them: the count is
   --    the number of index slots, not the number of regions that exist. The
   --    VGA region in particular is refused by every device that is not a
   --    display adapter
   --  @field Size Extent in bytes; zero for a region the device does not
   --    implement
   --  @field Offset Where the region lives within the device descriptor
   --  @field Readable The region can be read with pread
   --  @field Writable The region can be written with pwrite
   --  @field Mappable The region can be mapped with mmap
   --  @field Has_Capabilities The kernel has a capability chain to offer for
   --    this region, which needs a second, larger query to read
   type Region_Details is record
      Index            : Region_Index;
      Implemented      : Boolean;
      Size             : Flyology_DMA.Byte_Count;
      Offset           : Interfaces.Unsigned_64;
      Readable         : Boolean;
      Writable         : Boolean;
      Mappable         : Boolean;
      Has_Capabilities : Boolean;
   end record;

   --  Asks the kernel about one region.
   --
   --  A region index the device does not implement is reported with
   --  Implemented false rather than raised, because iterating a device's
   --  regions is the ordinary way to find out what it has and every PCI
   --  device has index slots it does not fill. Any other failure raises.
   --
   --  @param Device The device
   --  @param Index Which region
   --  @return What the kernel reports
   --  @exception Region_Error The query failed for a reason other than the
   --    region not existing
   function Describe
     (Device : Device_FD; Index : Region_Index) return Region_Details;

   --  One mapped region, released when it goes out of scope.
   type Window is limited private;

   --  Maps a region into the process.
   --
   --  Declare a Window after the device it comes from, so it is unmapped
   --  before the device descriptor closes.
   --
   --  @param Self The window to fill
   --  @param Device The device
   --  @param Index Which region to map
   --  @exception Region_Error The region is not mappable, has zero size, or
   --    the mapping failed
   procedure Map
     (Self   : in out Window;
      Device : Device_FD;
      Index  : Region_Index)
     with Pre => not Is_Mapped (Self), Post => Is_Mapped (Self);

   --  Whether the window currently holds a mapping.
   --  @param Self The window
   --  @return True between Map and Unmap
   function Is_Mapped (Self : Window) return Boolean;

   --  The address the region is mapped at.
   --
   --  This is the base for every register access. It is a host address the
   --  CPU dereferences, and is unrelated to any IOVA.
   --
   --  @param Self The window
   --  @return Address of the first mapped byte
   function Base (Self : Window) return System.Address
     with Pre => Is_Mapped (Self);

   --  How many bytes are mapped.
   --
   --  Every register accessor takes an offset and checks it against this, so
   --  a register address that is wrong by a BAR is a check failure rather
   --  than a read of whatever follows the mapping.
   --
   --  @param Self The window
   --  @return Extent in bytes
   function Length (Self : Window) return Flyology_DMA.Byte_Count
     with Pre => Is_Mapped (Self);

   --  Which region this window maps.
   --  @param Self The window
   --  @return The region index it was mapped from
   function Index_Of (Self : Window) return Region_Index
     with Pre => Is_Mapped (Self);

   --  Releases the mapping now rather than at finalization.
   --  @param Self The window to unmap
   procedure Unmap (Self : in out Window)
     with Post => not Is_Mapped (Self);

private

   type Window is limited new Ada.Finalization.Limited_Controlled with record
      Address : System.Address := System.Null_Address;
      Extent  : Flyology_DMA.Byte_Count := 0;
      Region  : Region_Index := 0;
      Mapped  : Boolean := False;
   end record;

   overriding procedure Finalize (Self : in out Window);

   function Is_Mapped (Self : Window) return Boolean is (Self.Mapped);
   function Base (Self : Window) return System.Address is (Self.Address);
   function Length (Self : Window) return Flyology_DMA.Byte_Count is
     (Self.Extent);
   function Index_Of (Self : Window) return Region_Index is (Self.Region);

end Flyology_VFIO.Regions;
