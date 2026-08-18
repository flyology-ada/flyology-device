with Interfaces;
use type Interfaces.Unsigned_16;

--  PCI configuration space, and the bit that makes DMA happen.
--
--  Configuration space is never mappable through VFIO. The kernel mediates
--  it — it hides and emulates parts of it — so it is reached with reads and
--  writes at an offset in the device descriptor rather than through a
--  pointer. That is why this is a separate package from
--  Flyology_VFIO.Registers, which deals only with mapped regions.
--
--  The reason this package exists at all is Enable_Bus_Mastering. VFIO does
--  not set the bus master enable bit for you: a device can be opened,
--  mapped, and programmed, and will still never issue a single DMA until
--  that bit is set. It is the most common way this whole exercise fails,
--  and the failure looks like nothing happening rather than like an error.
--  Nothing in the type system can force the call, so it is at least given
--  an unmissable name and said plainly here.
package Flyology_VFIO.Config_Space is

   subtype U8 is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;

   --  A byte offset into configuration space.
   type Config_Offset is range 0 .. 4095;

   --  Where the vendor identifier lives, in every PCI device ever made.
   Vendor_ID_Offset : constant Config_Offset := 16#00#;

   --  Where the device identifier lives.
   Device_ID_Offset : constant Config_Offset := 16#02#;

   --  The command register, which holds the enable bits below.
   Command_Offset : constant Config_Offset := 16#04#;

   --  The status register.
   Status_Offset : constant Config_Offset := 16#06#;

   --  The revision identifier.
   Revision_Offset : constant Config_Offset := 16#08#;

   --  Command register bit 0: the device answers I/O port accesses.
   Command_IO_Space : constant U16 := 2 ** 0;

   --  Command register bit 1: the device answers memory accesses, which is
   --  what makes a mapped BAR respond. Clearing it while a BAR is mapped
   --  makes accesses to that mapping fault.
   Command_Memory_Space : constant U16 := 2 ** 1;

   --  Command register bit 2: the device may act as a bus master, which is
   --  to say it may initiate DMA. Nothing else in this crate, and nothing
   --  in VFIO, sets it.
   Command_Bus_Master : constant U16 := 2 ** 2;

   --  Reads one byte of configuration space.
   --  @param Device The device
   --  @param At_Offset Byte offset within configuration space
   --  @return The byte read
   --  @exception Device_Error The read failed
   function Read_8 (Device : Device_FD; At_Offset : Config_Offset) return U8;

   --  Reads two bytes of configuration space.
   --  @param Device The device
   --  @param At_Offset Byte offset, which should be even
   --  @return The value read
   --  @exception Device_Error The read failed
   function Read_16
     (Device : Device_FD; At_Offset : Config_Offset) return U16;

   --  Reads four bytes of configuration space.
   --  @param Device The device
   --  @param At_Offset Byte offset, which should be a multiple of four
   --  @return The value read
   --  @exception Device_Error The read failed
   function Read_32
     (Device : Device_FD; At_Offset : Config_Offset) return U32;

   --  Writes two bytes of configuration space.
   --  @param Device The device
   --  @param At_Offset Byte offset, which should be even
   --  @param Value The value to write
   --  @exception Device_Error The write failed
   procedure Write_16
     (Device : Device_FD; At_Offset : Config_Offset; Value : U16);

   --  Writes four bytes of configuration space.
   --  @param Device The device
   --  @param At_Offset Byte offset, which should be a multiple of four
   --  @param Value The value to write
   --  @exception Device_Error The write failed
   procedure Write_32
     (Device : Device_FD; At_Offset : Config_Offset; Value : U32);

   --  The device's vendor identifier.
   --  @param Device The device
   --  @return The vendor identifier
   function Vendor_ID (Device : Device_FD) return U16
     with Pre => Devices_Is_Open (Device);

   --  The device's device identifier.
   --  @param Device The device
   --  @return The device identifier
   function Device_ID (Device : Device_FD) return U16
     with Pre => Devices_Is_Open (Device);

   --  Whether the device may initiate DMA.
   --  @param Device The device
   --  @return True when the bus master enable bit is set
   function Bus_Mastering_Enabled (Device : Device_FD) return Boolean;

   --  Lets the device initiate DMA.
   --
   --  Call this before expecting any DMA at all. A device that has been
   --  given descriptors, had its doorbell rung, and never had this bit set
   --  will sit silently and correctly doing nothing.
   --
   --  Also call it again after a device reset: what a reset preserves has
   --  varied, and a device that quietly lost the bit is indistinguishable
   --  from one that never had it.
   --
   --  @param Device The device
   --  @exception Device_Error The command register could not be written
   procedure Enable_Bus_Mastering (Device : Device_FD)
     with Post => Bus_Mastering_Enabled (Device);

   --  Stops the device initiating DMA.
   --
   --  Worth doing before tearing down mappings the device might still be
   --  writing into, though closing the device descriptor does it too.
   --
   --  @param Device The device
   --  @exception Device_Error The command register could not be written
   procedure Disable_Bus_Mastering (Device : Device_FD)
     with Post => not Bus_Mastering_Enabled (Device);

   --  Whether the device answers memory accesses.
   --  @param Device The device
   --  @return True when the memory space enable bit is set
   function Memory_Space_Enabled (Device : Device_FD) return Boolean;

   --  Lets the device answer memory accesses, which a mapped BAR needs.
   --  @param Device The device
   --  @exception Device_Error The command register could not be written
   procedure Enable_Memory_Space (Device : Device_FD)
     with Post => Memory_Space_Enabled (Device);

   --  Whether a device descriptor is open, restated so this package's
   --  contracts can mention it without depending on Flyology_VFIO.Devices.
   --  @param Device The device
   --  @return True when the descriptor is open
   function Devices_Is_Open (Device : Device_FD) return Boolean;

end Flyology_VFIO.Config_Space;
