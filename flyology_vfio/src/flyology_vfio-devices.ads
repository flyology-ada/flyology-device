with Flyology_VFIO.Containers;
with Flyology_VFIO.Groups;

--  A device taken out of the kernel's hands.
--
--  A device descriptor is obtained from a group, and only after that group
--  is attached to a container whose IOMMU has been set. Both of those are
--  preconditions here rather than comments, because the kernel refuses
--  otherwise with a bare EINVAL that names neither.
--
--  What this package does not do is enable bus mastering. VFIO leaves the
--  PCI command register alone, so a device obtained here can be mapped,
--  read, and written and will still never issue a single DMA. That bit is
--  set through Flyology_VFIO.Config_Space, deliberately as a separate and
--  obvious step, because "everything looks right and nothing happens" is
--  the most common way this whole exercise fails.
package Flyology_VFIO.Devices is

   --  Obtains a device descriptor by PCI address.
   --
   --  @param Self The device to open
   --  @param From The group the device belongs to
   --  @param In_Container The container that group is attached to
   --  @param Address The PCI address, such as "0000:00:02.0"
   --  @exception Device_Error The device could not be obtained
   procedure Open
     (Self         : in out Device_FD;
      From         : Group_FD;
      In_Container : Container_FD;
      Address      : String)
     with
       Pre =>
         not Is_Open (Self)
         and then Groups.Is_Attached_To (From, In_Container)
         and then Containers.IOMMU_Is_Set (In_Container);

   --  Whether the device descriptor is open.
   --  @param Self The device
   --  @return True between Open and Close
   function Is_Open (Self : Device_FD) return Boolean;

   --  How many regions the device exposes.
   --
   --  For a PCI device this is the six base address registers, the
   --  expansion ROM, and configuration space.
   --
   --  @param Self The device
   --  @return Count of regions
   function Region_Count (Self : Device_FD) return Natural
     with Pre => Is_Open (Self);

   --  How many interrupt indices the device exposes.
   --  @param Self The device
   --  @return Count of interrupt indices
   function IRQ_Count (Self : Device_FD) return Natural
     with Pre => Is_Open (Self);

   --  Whether the device reported itself as a PCI device.
   --  @param Self The device
   --  @return True when the kernel set the PCI flag
   function Is_PCI (Self : Device_FD) return Boolean
     with Pre => Is_Open (Self);

   --  Whether the device supports being reset.
   --  @param Self The device
   --  @return True when the kernel set the reset flag
   function Can_Reset (Self : Device_FD) return Boolean
     with Pre => Is_Open (Self);

   --  Resets the device.
   --
   --  After a reset, treat bus mastering and memory space enable as
   --  unknown and set them again. What the kernel preserves across a reset
   --  has varied, and a device that quietly lost bus mastering behaves
   --  exactly like one that never had it.
   --
   --  @param Self The device to reset
   --  @exception Device_Error The reset failed or is unsupported
   procedure Reset (Self : in out Device_FD)
     with Pre => Is_Open (Self) and then Can_Reset (Self);

   --  Closes the device descriptor.
   --
   --  vfio-pci disables the device as it goes, which includes clearing bus
   --  mastering, so nothing has to be undone by hand.
   --
   --  @param Self The device to close
   procedure Close (Self : in out Device_FD)
     with Post => not Is_Open (Self);

end Flyology_VFIO.Devices;
