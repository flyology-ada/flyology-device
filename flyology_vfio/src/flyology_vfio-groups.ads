with Flyology_VFIO.Containers;

--  The IOMMU group: the smallest set of devices the hardware can isolate.
--
--  VFIO assigns groups, not devices. If two functions share the IOMMU's
--  notion of a requester, the hardware cannot tell their DMA apart, so
--  handing one to a userspace process would hand it the other's memory
--  access as well. That is why a group must be viable — every device in it
--  bound to vfio-pci or to nothing — before the kernel will let go of it.
--
--  The ordering this package enforces is that a group is attached to a
--  container before that container's IOMMU is set, and that a device
--  descriptor is obtained only after both. Each of those failures is a bare
--  EINVAL from the kernel that names nothing.
package Flyology_VFIO.Groups is

   --  Opens the group with the given number.
   --
   --  The number is the one in /sys/bus/pci/devices/<address>/iommu_group,
   --  which Group_Of reads. Opening checks viability immediately, because a
   --  group that is not viable will fail later in a way that says less.
   --
   --  @param Self The group to open
   --  @param Number The IOMMU group number
   --  @exception VFIO_Unavailable /dev/vfio/<number> is absent
   --  @exception Group_Not_Viable A device in the group is still bound to a
   --    kernel driver
   --  @exception Group_Error The group could not be opened or queried
   procedure Open (Self : in out Group_FD; Number : Natural)
     with Pre => not Is_Open (Self);

   --  Whether the group is open.
   --  @param Self The group
   --  @return True between Open and Close
   function Is_Open (Self : Group_FD) return Boolean;

   --  The group's number.
   --  @param Self The group
   --  @return The IOMMU group number it was opened with
   function Number (Self : Group_FD) return Natural;

   --  Whether the group is attached to a container.
   --  @param Self The group
   --  @return True between Attach and Detach
   function Is_Attached (Self : Group_FD) return Boolean;

   --  Attaches the group to a container.
   --
   --  This must happen before the container's IOMMU is set. The reverse
   --  order is refused by the kernel with a bare EINVAL, which is why
   --  Containers.Set_IOMMU requires an attached group rather than
   --  documenting the requirement.
   --
   --  @param Self The group to attach
   --  @param To The container to attach it to
   --  @exception Group_Error The attachment was refused
   procedure Attach (Self : in out Group_FD; To : in out Container_FD)
     with
       Pre  =>
         Is_Open (Self)
         and then Containers.Is_Open (To)
         and then not Is_Attached (Self),
       Post => Is_Attached (Self);

   --  Detaches the group from its container.
   --
   --  Every mapping the container holds for this group's devices stops
   --  applying, so detach after the device descriptors are closed, not
   --  before.
   --
   --  @param Self The group to detach
   --  @param From The container it is attached to
   procedure Detach (Self : in out Group_FD; From : in out Container_FD)
     with Pre => Is_Attached (Self), Post => not Is_Attached (Self);

   --  Whether this group is attached to that container specifically.
   --
   --  Devices.Open needs to know, because it requires the IOMMU to have been
   --  set on the container this group is in, and there is nothing in a group
   --  descriptor that names its container.
   --
   --  @param Self The group
   --  @param Candidate The container to test against
   --  @return True when Self was attached to Candidate
   function Is_Attached_To
     (Self : Group_FD; Candidate : Container_FD) return Boolean;

   --  Closes the group.
   --  @param Self The group to close
   procedure Close (Self : in out Group_FD)
     with Post => not Is_Open (Self);

   --  The IOMMU group number of a PCI device.
   --
   --  Reads /sys/bus/pci/devices/<Address>/iommu_group. A device with no
   --  such link is either not bound to a driver that joins a group, or the
   --  host has no IOMMU; both are reported by name.
   --
   --  @param Address The device's PCI address, such as "0000:00:02.0"
   --  @return Its IOMMU group number
   --  @exception VFIO_Unavailable The device is in no IOMMU group
   function Group_Of (Address : String) return Natural;

end Flyology_VFIO.Groups;
