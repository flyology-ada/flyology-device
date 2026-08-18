private with Ada.Finalization;
private with Interfaces;
private with Interfaces.C;

--  The Linux VFIO userspace device interface.
--
--  VFIO lets a userspace process own a PCI device: map its BARs, receive its
--  interrupts, and program the IOMMU so the device can reach host memory the
--  process chose. This crate binds that interface and stops there. It has no
--  driver in it, no descriptor format, and no packet; what it hands back is a
--  mapped BAR, a working DMA mapping, and an interrupt.
--
--  It implements the Mapper that flyology_dma declares, which is what closes
--  the loop: flyology_dma owns the memory and knows nothing about VFIO, and
--  this crate knows how to make that memory visible to a device.
--
--  Three file descriptors matter, and they are different types here because
--  several VFIO request numbers mean different things depending on which one
--  they are sent to. VFIO_IOMMU_MAP_DMA and VFIO_DEVICE_PCI_HOT_RESET are
--  the same number; so are VFIO_IOMMU_GET_INFO and
--  VFIO_DEVICE_GET_PCI_HOT_RESET_INFO, and four more pairs besides. Nothing
--  in the number says which was meant. Distinct types put that distinction
--  where the compiler can enforce it.
package Flyology_VFIO
  with Preelaborate
is

   --  The container: an address space a device can be given access to.
   --
   --  Obtained by opening /dev/vfio/vfio. The IOMMU is programmed through
   --  this descriptor, so this is what a DMA mapping is made against.
   type Container_FD is limited private;

   --  The group: the smallest set of devices the IOMMU can isolate.
   --
   --  Obtained by opening /dev/vfio/<group>. Whole groups are assigned, not
   --  individual devices, because the hardware cannot isolate more finely.
   type Group_FD is limited private;

   --  The device itself, obtained from a group once that group is in a
   --  container with an IOMMU set.
   type Device_FD is limited private;

   --  Raised when the VFIO interface is not available on this host.
   --
   --  The message distinguishes the cases that need different fixes: no
   --  vfio module loaded, a kernel offering only the newer IOMMUFD character
   --  devices, or a host with no IOMMU enabled at all.
   VFIO_Unavailable : exception;

   --  Raised when the kernel reports an API version this crate does not
   --  implement. VFIO has had one version for its whole life, so this
   --  firing means something more surprising than a version bump.
   API_Mismatch : exception;

   --  Raised when the IOMMU type this crate needs is not offered.
   --
   --  It requires type1 version 2. No-IOMMU mode is refused by name: in that
   --  mode a device consumes physical addresses and no mapping ioctl exists,
   --  so nothing this crate does would mean what it says.
   IOMMU_Unsupported : exception;

   --  Raised when a group is not viable.
   --
   --  A group is viable when every device in it is bound to vfio-pci or to
   --  no driver at all. One stray device still held by a kernel driver
   --  blocks the whole group, and the message names the group so the
   --  offending device can be found.
   Group_Not_Viable : exception;

   --  Raised when an operation on a group fails for another reason.
   Group_Error : exception;

   --  Raised when a device operation fails, including the lifecycle
   --  orderings that must hold before a device descriptor can be obtained.
   Device_Error : exception;

   --  Raised when a device region cannot be queried or mapped.
   Region_Error : exception;

   --  Raised when interrupt setup fails.
   Interrupt_Error : exception;

private

   --  The three descriptor types are distinct so that the compiler can tell
   --  a container apart from a device, and they live here, in the root's
   --  private part, so that every child package can see their state. That
   --  matters because the lifecycle spans packages: whether a container may
   --  have its IOMMU set depends on whether a group has been attached to it,
   --  and the group is opened by a different package than the container.
   --  Putting the state where all the children can reach it is what lets the
   --  ordering be checked rather than documented.
   --
   --  All three close themselves. VFIO tears a great deal down when a
   --  descriptor closes — a container releases every mapping it holds, and
   --  vfio-pci disables the device — so leaking one leaks a device.
   type File_Descriptor is new Interfaces.C.int;

   --  Not a valid descriptor. Zero is standard input, so a closed
   --  descriptor cannot be zero without making a default-initialised value
   --  look usable.
   Invalid_Descriptor : constant File_Descriptor := -1;

   type Container_FD is limited new Ada.Finalization.Limited_Controlled with
   record
      Value : File_Descriptor := Invalid_Descriptor;
      --  How many groups have been attached. VFIO_SET_IOMMU is rejected
      --  until at least one has been, which is the ordering that fails most
      --  confusingly when it is got wrong.
      Groups : Natural := 0;
      --  Whether VFIO_SET_IOMMU has succeeded. Device descriptors and DMA
      --  mappings both require it.
      IOMMU_Set : Boolean := False;
   end record;

   overriding procedure Finalize (Self : in out Container_FD);

   type Group_FD is limited new Ada.Finalization.Limited_Controlled with
   record
      Value    : File_Descriptor := Invalid_Descriptor;
      Number   : Natural         := 0;
      Attached : Boolean         := False;
      --  Which container this group joined. A group descriptor carries no
      --  reference to its container, and opening a device requires the
      --  IOMMU to have been set on the container this group is in, so the
      --  association has to be recorded to be checkable.
      Container : File_Descriptor := Invalid_Descriptor;
   end record;

   overriding procedure Finalize (Self : in out Group_FD);

   type Device_FD is limited new Ada.Finalization.Limited_Controlled with
   record
      Value : File_Descriptor := Invalid_Descriptor;
      --  Regions, interrupts and capability flags all come from one
      --  VFIO_DEVICE_GET_INFO at open time, because none of them changes
      --  and asking again costs a syscall on a path a driver may be on.
      Flags        : Interfaces.Unsigned_32 := 0;
      Region_Count : Natural := 0;
      IRQ_Count    : Natural := 0;
   end record;

   overriding procedure Finalize (Self : in out Device_FD);

end Flyology_VFIO;
