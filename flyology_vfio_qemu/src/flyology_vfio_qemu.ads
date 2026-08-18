with Interfaces;

--  Driving QEMU's virtual PCI devices through flyology_vfio.
--
--  This crate exists to answer one question the layers below it cannot
--  answer about themselves: does any of it actually work against a device?
--  flyology_dma can be tested against ordinary memory and flyology_vfio can
--  be tested against the kernel's own refusals, but neither tells you
--  whether an IOVA this code programmed is one a device can follow. Only a
--  device dereferencing that address can.
--
--  The devices here are QEMU's, and they exist in no silicon. That is the
--  point and also the limit.
--
--  What it validates honestly: the IOMMU path. With an emulated SMMU, QEMU
--  walks its page tables when a device dereferences an address, so an IOVA
--  programmed incorrectly produces a translation fault rather than quietly
--  working. That is the property most worth testing and the hardest to test
--  any other way, and QEMU's educational device has a DMA engine that will
--  follow whatever address it is given.
--
--  What it validates about hardware: nothing. There is no bus timing here,
--  no errata, no write-combining, no MSI-X table with a sparse-mmap hole,
--  no 64-bit or multi-BAR layouts. A result from this crate is a result
--  about the binding, not about a device.
--
--  This is a harness, not a driver. Nothing here is meant to be depended on
--  by anything that has to work.
package Flyology_VFIO_QEMU is

   subtype U8 is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   --  A PCI address in the full domain:bus:device.function form.
   subtype PCI_Address is String (1 .. 12);

   --  Raised when the harness cannot find or use a device it needs.
   --
   --  Distinct from the exceptions flyology_vfio raises: those mean the
   --  interface refused something, while this means the environment is not
   --  set up. The messages say which command would set it up, because this
   --  crate is the one people run on an unfamiliar machine.
   Device_Not_Available : exception;

   --  Raised when a device did not behave as its specification says.
   --
   --  This is the interesting failure. It means either the device is not
   --  what it claimed, or — far more likely — the layers below this one got
   --  something wrong.
   Device_Misbehaved : exception;

   --  Finds a device by its PCI identity, if one is present and usable.
   --
   --  Searches /sys/bus/pci/devices for a device with the given vendor and
   --  device identifiers that is bound to vfio-pci. A device that exists
   --  but is bound elsewhere is reported as not found, with a message
   --  saying so, because binding it is not this crate's decision to make.
   --
   --  Instance selects among several devices of the same identity, in the
   --  order the addresses sort. Two of one device is how a container
   --  holding more than one group gets tested.
   --
   --  @param Vendor The PCI vendor identifier
   --  @param Device The PCI device identifier
   --  @param Instance Which of the matching devices to return, from one
   --  @return The device's address
   --  @exception Device_Not_Available No such device is bound to vfio-pci
   function Find
     (Vendor : U16; Device : U16; Instance : Positive := 1) return String;

   --  How many devices of this identity are bound to vfio-pci.
   --  @param Vendor The PCI vendor identifier
   --  @param Device The PCI device identifier
   --  @return Count of usable devices
   function Available (Vendor : U16; Device : U16) return Natural;

   --  Whether a device with this identity exists at all, bound or not.
   --  @param Vendor The PCI vendor identifier
   --  @param Device The PCI device identifier
   --  @return True when the device is present in the system
   function Exists (Vendor : U16; Device : U16) return Boolean;

   --  Which driver holds a device, or the empty string when none does.
   --  @param Address The device's PCI address
   --  @return The driver's name, or ""
   function Driver_Of (Address : String) return String;

   --  A four-digit lowercase hexadecimal rendering, for identity messages.
   --  @param Value The value to render
   --  @return Exactly four hexadecimal digits
   function Hex_16 (Value : U16) return String;

   --  An eight-digit lowercase hexadecimal rendering.
   --  @param Value The value to render
   --  @return Exactly eight hexadecimal digits
   function Hex_32 (Value : U32) return String;

end Flyology_VFIO_QEMU;
