private with Ada.Finalization;
with Flyology_DMA.Regions;
with System;

--  Making host memory visible to a device, without knowing how.
--
--  Establishing an I/O virtual address is inherently the business of
--  whatever kernel interface owns the IOMMU. For VFIO that is an ioctl on a
--  container file descriptor, which would make this crate depend on the one
--  that opens /dev/vfio. Rather than invert the dependency, this package
--  declares an abstract Mapper and performs no mapping itself. The
--  flyology_vfio crate implements it; so could a future no-IOMMU backend, a
--  platform-bus backend, or the test mapper below.
--
--  The lifetime rule this package exists to enforce: a device-visible
--  mapping is a resource distinct from the memory behind it, and it must be
--  torn down first. A Mapping value owns that binding and removes it on
--  finalization. Declaring a Mapping after the Region it maps, in the same
--  scope, produces the correct order for free, because Ada finalizes in
--  reverse declaration order.
package Flyology_DMA.Mappers is

   --  What the device is allowed to do with the mapped memory.
   --
   --  This is the device's view, not the process's: a receive buffer the
   --  device fills is Device_Writes, and a transmit buffer the device reads
   --  is Device_Reads. Granting only what a buffer needs is what lets the
   --  IOMMU refuse a device that has gone wrong.
   --
   --  @enum Device_Reads The device may read, and must not write
   --  @enum Device_Writes The device may write, and must not read
   --  @enum Device_Reads_And_Writes The device may do both
   type Device_Access is
     (Device_Reads, Device_Writes, Device_Reads_And_Writes);

   --  A backend that can make host memory visible to a device.
   --
   --  Implementations are limited and controlled. Finalizing a mapper that
   --  still has live Mappings raises Program_Error, because the alternative
   --  is a Mapping whose Finalize calls into a mapper that no longer
   --  exists, which is a silent use-after-free of the thing whose whole job
   --  is preventing silent memory corruption.
   type Mapper is abstract tagged limited private;

   --  Establishes a device-visible mapping.
   --
   --  Implementations must map exactly the requested extent. Callers should
   --  prefer Map_Region, which pairs this with a Mapping that removes the
   --  binding again.
   --
   --  @param Self The mapper
   --  @param Host_Base First byte of the host memory to map
   --  @param Length Extent in bytes; a whole number of pages
   --  @param IOVA Device-visible address to map it at
   --  @param Direction What the device may do with it
   --  @exception Mapping_Error The mapping could not be established
   procedure Map
     (Self      : in out Mapper;
      Host_Base : System.Address;
      Length    : Byte_Count;
      IOVA      : IOVA_Address;
      Direction : Device_Access) is abstract;

   --  Removes a mapping previously established by Map.
   --
   --  IOVA and Length must be exactly those of a prior Map. Partial unmapping
   --  is not offered, and implementations need not support it: the VFIO type1
   --  IOMMU cannot split an existing mapping, and an interface that appeared
   --  to allow it would work on some backends and silently not on others.
   --
   --  @param Self The mapper
   --  @param IOVA Device-visible address of the mapping to remove
   --  @param Length Extent in bytes, matching the original Map
   --  @exception Mapping_Error The mapping could not be removed
   procedure Unmap
     (Self   : in out Mapper;
      IOVA   : IOVA_Address;
      Length : Byte_Count) is abstract;

   --  The number of mappings this mapper has established and not removed.
   --  @param Self The mapper
   --  @return Count of live mappings
   function Live_Mappings (Self : Mapper) return Natural;

   --  One live device-visible mapping of one region.
   --
   --  Removes itself on finalization. It is limited, so it cannot be copied
   --  into a second value that would remove the same mapping twice.
   type Mapping is tagged limited private;

   --  Maps a whole region at the given IOVA.
   --
   --  @param Through The mapper to establish the mapping with
   --  @param Subject The region to map; mapped in its entirety
   --  @param IOVA Device-visible address of the region's first byte
   --  @param Direction What the device may do with it
   --  @return The live mapping
   --  @exception Mapping_Error The mapping could not be established
   function Map_Region
     (Through   : not null access Mapper'Class;
      Subject   : Regions.Region;
      IOVA      : IOVA_Address;
      Direction : Device_Access := Device_Reads_And_Writes) return Mapping;

   --  The host address of the mapped memory.
   --  @param Self The mapping
   --  @return Host virtual address of the first mapped byte
   function Host_Base (Self : Mapping) return System.Address;

   --  The device-visible address of the mapped memory.
   --  @param Self The mapping
   --  @return IOVA of the first mapped byte
   function IOVA_Base (Self : Mapping) return IOVA_Address;

   --  The extent of the mapping in bytes.
   --  @param Self The mapping
   --  @return Length in bytes
   function Length (Self : Mapping) return Byte_Count;

   --  Whether the mapping is still established.
   --  @param Self The mapping
   --  @return True until Release or finalization removes it
   function Is_Live (Self : Mapping) return Boolean;

   --  Removes the mapping now rather than at finalization.
   --
   --  Idempotent: releasing an already-released mapping does nothing, so a
   --  scope that releases explicitly and then finalizes is correct.
   --
   --  @param Self The mapping to release
   --  @exception Mapping_Error The mapping could not be removed
   procedure Release (Self : in out Mapping);

   --  A mapper that establishes no mapping at all.
   --
   --  It records what it was asked to map, so tests can assert on the calls,
   --  and it hands back the IOVA it was given unchanged. Nothing is
   --  programmed into any IOMMU.
   --
   --  This is meaningful only where no device consumes the IOVA: unit tests
   --  of the pool and address-space code, and drivers under test against a
   --  mock. It is not a no-IOMMU backend. Without an IOMMU a device consumes
   --  physical addresses, so handing it host virtual addresses would scatter
   --  device writes across whatever physical memory happened to answer, with
   --  nothing left to catch the mistake. A real no-IOMMU backend has to
   --  resolve host pages to physical addresses and guarantee their
   --  contiguity, and is a different implementation entirely.
   type Identity_Mapper is limited new Mapper with private;

   --  Records the mapping and does nothing else.
   overriding procedure Map
     (Self      : in out Identity_Mapper;
      Host_Base : System.Address;
      Length    : Byte_Count;
      IOVA      : IOVA_Address;
      Direction : Device_Access);

   --  Forgets a recorded mapping. Raises if it was never recorded.
   overriding procedure Unmap
     (Self   : in out Identity_Mapper;
      IOVA   : IOVA_Address;
      Length : Byte_Count);

   --  The largest number of simultaneous mappings an Identity_Mapper records.
   Identity_Mapper_Capacity : constant := 64;

   --  The direction recorded for a live mapping at the given IOVA.
   --  @param Self The mapper
   --  @param IOVA The device-visible address to look up
   --  @return The direction the mapping was established with
   --  @exception Mapping_Error No live mapping starts at that IOVA
   function Recorded_Direction
     (Self : Identity_Mapper; IOVA : IOVA_Address) return Device_Access;

private

   type Mapper is abstract limited new Ada.Finalization.Limited_Controlled
   with record
      Live : Natural := 0;
   end record;

   overriding procedure Finalize (Self : in out Mapper);

   function Live_Mappings (Self : Mapper) return Natural is (Self.Live);

   --  A Mapping refers back to the mapper that established it, so that it
   --  can remove the mapping when it goes out of scope. Ada's accessibility
   --  rules cannot express the relationship that actually holds here: the
   --  language would have to know that the mapper outlives every Mapping
   --  made from it, and neither a named access type nor an anonymous access
   --  component can be told that. Both reject the ordinary case, where a
   --  mapper and its mappings are declared in the same subprogram.
   --
   --  What stands in for the check is the mapper's count of live mappings.
   --  Finalizing a mapper that still has live mappings raises Program_Error
   --  naming the count, so the arrangement this reference could not survive
   --  is caught at the moment it is created rather than the moment it is
   --  dereferenced. See the Finalize for Mapper in the body.
   type Mapper_Reference is access all Mapper'Class;

   type Mapping is limited new Ada.Finalization.Limited_Controlled with record
      Through   : Mapper_Reference := null;
      Host      : System.Address   := System.Null_Address;
      Device    : IOVA_Address     := 0;
      Extent    : Byte_Count       := 0;
      Direction : Device_Access    := Device_Reads_And_Writes;
      Active    : Boolean          := False;
   end record;

   overriding procedure Finalize (Self : in out Mapping);

   function Host_Base (Self : Mapping) return System.Address is (Self.Host);
   function IOVA_Base (Self : Mapping) return IOVA_Address is (Self.Device);
   function Length (Self : Mapping) return Byte_Count is (Self.Extent);
   function Is_Live (Self : Mapping) return Boolean is (Self.Active);

   type Record_Entry is record
      In_Use    : Boolean       := False;
      Host      : System.Address := System.Null_Address;
      Device    : IOVA_Address  := 0;
      Extent    : Byte_Count    := 0;
      Direction : Device_Access := Device_Reads_And_Writes;
   end record;

   type Record_Table is
     array (1 .. Identity_Mapper_Capacity) of Record_Entry;

   type Identity_Mapper is limited new Mapper with record
      Entries : Record_Table;
   end record;

end Flyology_DMA.Mappers;
