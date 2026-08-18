with Interfaces;

--  The VFIO container: the address space a device is given access to.
--
--  A container is opened, groups are attached to it, and only then is its
--  IOMMU type set. That order is not a convention: VFIO_SET_IOMMU on a
--  container with no group attached is rejected, and the rejection is a
--  bare EINVAL that says nothing about what was missing. The precondition on
--  Set_IOMMU says it instead.
--
--  Once the IOMMU is set, the container is what DMA mappings are made
--  against, which is why Flyology_VFIO.DMA_Mapper takes one.
package Flyology_VFIO.Containers is

   --  The path every VFIO container is opened from.
   Device_Node : constant String := "/dev/vfio/vfio";

   --  Opens a container and checks that this kernel offers what is needed.
   --
   --  Three things are checked here rather than later, because each has a
   --  different fix and each is invisible once the failure has moved on:
   --  that the interface exists at all, that its API version is the one this
   --  crate implements, and that the type1 version 2 IOMMU is available.
   --
   --  @param Self The container to open
   --  @exception VFIO_Unavailable The interface is absent on this host
   --  @exception API_Mismatch The kernel reports an unexpected API version
   --  @exception IOMMU_Unsupported Type1 version 2 is not offered
   procedure Open (Self : in out Container_FD)
     with Pre => not Is_Open (Self);

   --  Whether the container is open.
   --  @param Self The container
   --  @return True between Open and Close
   function Is_Open (Self : Container_FD) return Boolean;

   --  How many groups have been attached to this container.
   --  @param Self The container
   --  @return Count of attached groups
   function Attached_Groups (Self : Container_FD) return Natural;

   --  Whether the IOMMU type has been set.
   --  @param Self The container
   --  @return True once Set_IOMMU has succeeded
   function IOMMU_Is_Set (Self : Container_FD) return Boolean;

   --  Sets the IOMMU type to type1 version 2.
   --
   --  Must follow at least one group attachment, which is what the
   --  precondition states. Until this succeeds, no device descriptor can be
   --  obtained from any attached group and no memory can be mapped.
   --
   --  @param Self The container
   --  @exception IOMMU_Unsupported The kernel refused the IOMMU type
   procedure Set_IOMMU (Self : in out Container_FD)
     with
       Pre  =>
         Is_Open (Self)
         and then Attached_Groups (Self) > 0
         and then not IOMMU_Is_Set (Self),
       Post => IOMMU_Is_Set (Self);

   --  The page sizes this IOMMU can map, as a bitmask of sizes.
   --
   --  Bit n set means the IOMMU can map at a granularity of 2**n bytes. A
   --  region mapped at a finer granularity than the smallest supported size
   --  is refused, which is one of the ways a mapping fails with EINVAL for
   --  reasons that have nothing to do with the addresses in it.
   --
   --  @param Self The container
   --  @return The mask, or zero when the kernel did not report one
   function Supported_Page_Sizes
     (Self : Container_FD) return Interfaces.Unsigned_64
     with Pre => IOMMU_Is_Set (Self);

   --  Closes the container.
   --
   --  Every mapping made through it goes away with it. Rely on that only as
   --  a backstop: mappings are owned by the Mapping values that made them.
   --
   --  @param Self The container to close
   procedure Close (Self : in out Container_FD)
     with Post => not Is_Open (Self);

end Flyology_VFIO.Containers;
