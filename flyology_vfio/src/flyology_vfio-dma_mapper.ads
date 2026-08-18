with Flyology_DMA;
with Flyology_DMA.Mappers;
with System;

--  Making host memory visible to a device through a VFIO container.
--
--  This is the concrete Mapper that flyology_dma declares abstractly, and
--  it is what closes the loop between the two crates: flyology_dma owns
--  hugepage memory and knows nothing about VFIO, and this programs the
--  IOMMU so a device can reach it.
--
--  What a mapping costs is worth knowing. VFIO pins the pages at map time
--  and charges them against RLIMIT_MEMLOCK. That pin, not mlock, is what
--  makes the memory safe for a device to write into, and it is why
--  flyology_dma does not lock regions by default: locking a region that is
--  about to be mapped charges the same budget twice.
package Flyology_VFIO.DMA_Mapper is

   --  A mapper that programs one container's IOMMU.
   type Container_Mapper is limited new Flyology_DMA.Mappers.Mapper
     with private;

   --  Points a mapper at a container.
   --
   --  The container must outlive the mapper, and the mapper must outlive
   --  every Mapping made from it. The second of those is checked:
   --  flyology_dma raises Program_Error when a mapper with live mappings is
   --  finalized. The first is not, because a descriptor carries no way to
   --  ask whether it is still open; declare the container before the mapper
   --  and the ordinary finalization order is right.
   --
   --  @param Self The mapper to bind
   --  @param To The container whose IOMMU it will program
   procedure Bind (Self : in out Container_Mapper; To : Container_FD)
     with Post => Is_Bound (Self);

   --  Whether the mapper has been pointed at a container.
   --  @param Self The mapper
   --  @return True after Bind
   function Is_Bound (Self : Container_Mapper) return Boolean;

   --  Establishes a device-visible mapping of host memory.
   --
   --  @param Self The mapper
   --  @param Host_Base First byte of the host memory to map
   --  @param Length Extent in bytes
   --  @param IOVA The address the device will use
   --  @param Direction What the device may do with the memory
   --  @exception Flyology_DMA.Mapping_Error The mapping was refused
   overriding procedure Map
     (Self      : in out Container_Mapper;
      Host_Base : System.Address;
      Length    : Flyology_DMA.Byte_Count;
      IOVA      : Flyology_DMA.IOVA_Address;
      Direction : Flyology_DMA.Mappers.Device_Access);

   --  Removes a mapping.
   --
   --  IOVA and Length must match a prior Map exactly. The type1 IOMMU
   --  cannot split an existing mapping, so a partial unmap is not a smaller
   --  unmap; it removes whole mappings that fall inside the range and
   --  leaves the rest.
   --
   --  @param Self The mapper
   --  @param IOVA The mapping's device-visible address
   --  @param Length The mapping's extent
   --  @exception Flyology_DMA.Mapping_Error The unmapping failed
   overriding procedure Unmap
     (Self   : in out Container_Mapper;
      IOVA   : Flyology_DMA.IOVA_Address;
      Length : Flyology_DMA.Byte_Count);

private

   type Container_Mapper is limited new Flyology_DMA.Mappers.Mapper with
   record
      --  The container's descriptor rather than a reference to it. A
      --  reference would need an access type whose accessibility rules
      --  cannot express "the container outlives this", and would not make
      --  the dangling case detectable anyway.
      Container : File_Descriptor := Invalid_Descriptor;
   end record;

   function Is_Bound (Self : Container_Mapper) return Boolean is
     (Self.Container /= Invalid_Descriptor);

end Flyology_VFIO.DMA_Mapper;
