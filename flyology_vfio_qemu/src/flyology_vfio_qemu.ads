with Flyology_DMA;
with Interfaces;
use type Flyology_DMA.IOVA_Address;
use type Interfaces.Unsigned_64;

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
--  any other way. Four devices exercise it between them, from an
--  educational DMA engine that follows a single address to a storage
--  controller that reaches three separately programmed ones in a single
--  operation.
--
--  It also covers shapes the interface has to handle and the simplest
--  devices never show: a sixty-four bit base address register, several
--  regions on one device, regions the kernel decorates with a capability
--  chain, more than one interrupt vector, and a container holding more
--  than one group.
--
--  What it validates about hardware: nothing. There is no bus timing here,
--  no errata, no write-combining, and no silicon to have errata in the
--  first place. A result from this crate is a result about the binding,
--  not about a device.
--
--  This is a harness, not a driver. Nothing here is meant to be depended on
--  by anything that has to work.
package Flyology_VFIO_QEMU is

   subtype U8 is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   --  An address as a device puts it on the bus.
   --
   --  The same type flyology_dma programs into the IOMMU, so a value
   --  crosses that boundary without a conversion and a host address cannot
   --  cross it at all. Every parameter below that a device dereferences is
   --  one of these rather than a plain sixty-four bit number, which is the
   --  rule the layers underneath have followed from the start and this
   --  crate did not — leaving the weakest typing of the defining mistake in
   --  the one place built to demonstrate it. Two adjacent parameters, a
   --  block number and the address to put it at, used to be the same type
   --  and swapping them compiled.
   subtype Device_Address is Flyology_DMA.IOVA_Address;

   --  The low and high halves of a device address.
   --
   --  Every ring base, queue base and data pointer in this crate is given
   --  to its device as two thirty-two bit registers, so this pair of
   --  operations appears everywhere. Named, because "shift right by
   --  thirty-two" written out twenty times is twenty chances to write
   --  thirty-one.
   --
   --  @param Value The address to split
   --  @return The half named
   function Low_Half (Value : Device_Address) return U32
     is (U32 (Value mod 2 ** 32));

   function High_Half (Value : Device_Address) return U32
     is (U32 (Value / 2 ** 32));

   --  And for the values that are not addresses but are still handed over
   --  in two pieces — a starting block, most often. Overloaded rather than
   --  named apart because the operation is the same one; what differs is
   --  what is being split, and the type says that.
   function Low_Half (Value : U64) return U32
     is (U32 (Value and 16#FFFF_FFFF#));

   function High_Half (Value : U64) return U32
     is (U32 (Interfaces.Shift_Right (Value, 32)));

   --  A PCI address in the full domain:bus:device.function form.
   --
   --  A subtype rather than a type, so it costs nothing at a call site and
   --  still says in a signature which strings are addresses. Find returns
   --  one of these and Driver_Of takes one.
   subtype PCI_Address is String (1 .. 12);

   --  Raised when the harness cannot find or use a device it needs.
   --
   --  Distinct from the exceptions flyology_vfio raises: those mean the
   --  interface refused something, while this means the environment is not
   --  set up. The messages say which command would set it up, because this
   --  crate is the one people run on an unfamiliar machine.
   Device_Not_Available : exception;

   --  Raised when this crate was asked for something it cannot do.
   --
   --  A transfer that is not a whole number of blocks, a range past the end
   --  of a namespace, a buffer size no register can name. These are the
   --  caller's mistakes, and they were once reported as the device
   --  misbehaving — which pollutes the one exception that means "something
   --  below this is wrong" with the many ways of asking wrongly, and leaves
   --  nobody able to trust the name.
   Device_Misused : exception;

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
     (Vendor : U16; Device : U16; Instance : Positive := 1)
      return PCI_Address;

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
   function Driver_Of (Address : PCI_Address) return String;

   --  A four-digit lowercase hexadecimal rendering, for identity messages.
   --  @param Value The value to render
   --  @return Exactly four hexadecimal digits
   function Hex_16 (Value : U16) return String;

   --  An eight-digit lowercase hexadecimal rendering.
   --  @param Value The value to render
   --  @return Exactly eight hexadecimal digits
   function Hex_32 (Value : U32) return String;

end Flyology_VFIO_QEMU;
