with Flyology_VFIO.Regions;
with Interfaces;
use type Interfaces.Unsigned_8;
use type Interfaces.Unsigned_32;

--  An Intel 82574L gigabit controller, as QEMU emulates it.
--
--  This device is here for its shape rather than for what it does. It is
--  the first thing in this repository with more than one base address
--  register, the first with a region the kernel decorates with a
--  capability chain, and the first offering more than one interrupt
--  vector. Those are three parts of Flyology_VFIO that nothing else
--  exercises.
--
--  It also offers a corpus worth having. Its receive address registers hold
--  a MAC address chosen on the command line that started the machine, so a
--  value picked outside this program can be recovered through MMIO and
--  compared. That is a stronger check than any self-consistency test: a
--  register window that reads plausible-looking rubbish fails it.
--
--  There is no packet handling here, no ring, and no link management. This
--  reads identity, resets the device, and stops.
package Flyology_VFIO_QEMU.E1000E is

   package Regions renames Flyology_VFIO.Regions;

   --  Intel.
   Vendor_ID : constant U16 := 16#8086#;

   --  The 82574L, which is what QEMU's e1000e emulates.
   Device_ID : constant U16 := 16#10D3#;

   --  Registers live in the first region. The others are a flash window, an
   --  I/O port window, and the interrupt vector table.
   Register_BAR : constant Regions.Region_Index := 0;

   --  Device control.
   Control_Register : constant := 16#00000#;

   --  Device status.
   Status_Register : constant := 16#00008#;

   --  Extended device control.
   Extended_Control_Register : constant := 16#00018#;

   --  The low half of the first receive address, holding the first four
   --  bytes of the MAC address.
   Receive_Address_Low : constant := 16#05400#;

   --  The high half, holding the last two bytes and the validity bit.
   Receive_Address_High : constant := 16#05404#;

   --  Set in the control register to reset the device. The device clears it
   --  itself once the reset is complete.
   Control_Reset : constant U32 := 2 ** 26;

   --  Set in the control register to set the link up.
   Control_Set_Link_Up : constant U32 := 2 ** 6;

   --  Set in the status register while the link is up.
   Status_Link_Up : constant U32 := 2 ** 1;

   --  Set in the high half of a receive address when it holds a real one.
   Receive_Address_Valid : constant U32 := 2 ** 31;

   --  A hardware address, in the order the bytes appear on the wire.
   type MAC_Address is array (1 .. 6) of U8;

   --  Reads the first receive address out of the device.
   --
   --  @param BAR The device's mapped registers
   --  @return The address the device holds
   function Hardware_Address (BAR : Regions.Window) return MAC_Address;

   --  Whether the device says its first receive address is a real one.
   --  @param BAR The device's mapped registers
   --  @return True when the validity bit is set
   function Hardware_Address_Valid (BAR : Regions.Window) return Boolean;

   --  Renders an address in the usual colon-separated hexadecimal.
   --  @param Address The address to render
   --  @return Seventeen characters
   function Image (Address : MAC_Address) return String;

   --  Parses an address from colon-separated hexadecimal.
   --  @param Text The text to parse
   --  @return The address
   --  @exception Device_Not_Available The text is not an address
   function Value (Text : String) return MAC_Address;

   --  Resets the device and waits for it to finish.
   --
   --  The device clears the reset bit itself when it is done, which makes
   --  this one of the few places where a register a driver wrote comes back
   --  changed by the hardware rather than by anything the driver did.
   --
   --  @param BAR The device's mapped registers
   --  @param Attempts How many times to poll before giving up
   --  @exception Device_Misbehaved The device did not finish resetting
   procedure Reset (BAR : Regions.Window; Attempts : Positive := 20_000);

end Flyology_VFIO_QEMU.E1000E;
