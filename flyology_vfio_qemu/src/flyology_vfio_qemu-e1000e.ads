with Flyology_VFIO.Regions;
with Interfaces;
with System;
use type Interfaces.Unsigned_8;
use type Interfaces.Unsigned_16;
use type Interfaces.Unsigned_64;
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

   --  The window onto the physical-layer chip, which is a separate device
   --  reached through this register rather than through the memory map.
   MDI_Control_Register : constant := 16#00020#;

   --  The window onto the non-volatile memory holding the device's
   --  configuration, including the hardware address it powers up with.
   EEPROM_Read_Register : constant := 16#00014#;

   --  Interrupt cause, read to find out why the device interrupted.
   Interrupt_Cause_Register : constant := 16#000C0#;

   --  Interrupt cause set, written to provoke a cause. It exists so that a
   --  driver can test its own interrupt path without waiting for the
   --  device to have a reason.
   Interrupt_Cause_Set_Register : constant := 16#000C8#;

   --  Interrupt mask set, written to ask for interrupts.
   Interrupt_Mask_Set_Register : constant := 16#000D0#;

   --  Interrupt mask clear, written to stop asking.
   Interrupt_Mask_Clear_Register : constant := 16#000D8#;

   --  Receive control.
   Receive_Control_Register : constant := 16#00100#;

   --  Transmit control.
   Transmit_Control_Register : constant := 16#00400#;

   --  Inter-packet gap timing.
   Transmit_Gap_Register : constant := 16#00410#;

   --  Where the receive descriptor ring lives, low then high.
   Receive_Base_Low_Register  : constant := 16#02800#;
   Receive_Base_High_Register : constant := 16#02804#;

   --  How long the receive ring is, in bytes.
   Receive_Length_Register : constant := 16#02808#;

   --  The descriptor the device will fill next.
   Receive_Head_Register : constant := 16#02810#;

   --  The last descriptor the driver has given the device.
   Receive_Tail_Register : constant := 16#02818#;

   --  The same four for transmit.
   Transmit_Base_Low_Register  : constant := 16#03800#;
   Transmit_Base_High_Register : constant := 16#03804#;
   Transmit_Length_Register    : constant := 16#03808#;
   Transmit_Head_Register      : constant := 16#03810#;
   Transmit_Tail_Register      : constant := 16#03818#;

   --  Counters the device keeps. Both clear when read, which makes them a
   --  useful check of the rule that a read-clearing register must never be
   --  read-modify-written.
   Good_Packets_Received_Register    : constant := 16#04074#;
   Good_Packets_Transmitted_Register : constant := 16#04080#;

   --  Set in the receive control register to route transmitted frames
   --  straight back into the receive path, without them leaving the
   --  device. It makes both directions testable with nothing attached.
   Receive_Loopback : constant U32 := 3 * 2 ** 6;

   --  Interrupt causes worth naming. Every one is cleared by reading the
   --  cause register, which is the classic register that must never be
   --  read-modify-written: the read is the acknowledgement.
   Interrupt_Transmit_Done : constant U32 := 2 ** 0;
   Interrupt_Link_Change   : constant U32 := 2 ** 2;
   Interrupt_Receive_Timer : constant U32 := 2 ** 7;

   --  Set in the receive control register to enable receiving.
   Receive_Enable : constant U32 := 2 ** 1;

   --  Set to accept broadcast frames, which an address resolution reply
   --  is not, but the request that provokes it is.
   Receive_Broadcast : constant U32 := 2 ** 15;

   --  Set to have the device strip the frame check sequence, so the length
   --  a descriptor reports is the length of the frame proper.
   Receive_Strip_CRC : constant U32 := 2 ** 26;

   --  Set in the transmit control register to enable transmitting.
   Transmit_Enable : constant U32 := 2 ** 1;

   --  Set to have the device pad short frames to the minimum length.
   Transmit_Pad_Short : constant U32 := 2 ** 3;

   --  Set in a descriptor's status byte once the device has finished with
   --  it. It is how a driver knows a frame has gone or arrived, and it is
   --  written by the device into memory the driver owns.
   Descriptor_Done : constant U8 := 2 ** 0;

   --  Set in a receive descriptor's status when the frame ends there.
   Descriptor_End_Of_Packet : constant U8 := 2 ** 1;

   --  Set in a transmit descriptor's command byte: this is the last
   --  descriptor of the frame, insert a frame check sequence, and report
   --  when done.
   Transmit_End_Of_Packet : constant U8 := 2 ** 0;
   Transmit_Insert_CRC    : constant U8 := 2 ** 1;
   Transmit_Report_Status : constant U8 := 2 ** 3;

   --  How large a descriptor is, in bytes, in both rings.
   Descriptor_Bytes : constant := 16;

   --  How large each receive buffer is. The receive control register's
   --  default size, chosen because it holds any frame this test sends.
   Receive_Buffer_Bytes : constant := 2048;

   --  A hardware address, in the order the bytes appear on the wire.
   type MAC_Address is array (1 .. 6) of U8;

   --  Which register of the physical-layer chip. There are thirty-two in
   --  the basic set, of which the first two are standardised across every
   --  such chip ever made and the rest are the vendor's business.
   type PHY_Register is new Natural range 0 .. 31;

   --  The basic control register, present in every physical-layer chip.
   PHY_Control : constant PHY_Register := 0;

   --  The basic status register.
   PHY_Status : constant PHY_Register := 1;

   --  The two halves of the chip's identity.
   PHY_Identifier_High : constant PHY_Register := 2;
   PHY_Identifier_Low  : constant PHY_Register := 3;

   --  Reads one register of the physical-layer chip.
   --
   --  This is a second device behind the first, reached by writing a
   --  request and waiting for a ready bit — a small bus inside the register
   --  window. It is worth exercising because it is the one place where a
   --  read is not a read: the value arrives in the same register the
   --  request was written to, and only after the device says so.
   --
   --  @param BAR The device's mapped registers
   --  @param Number Which physical-layer register
   --  @param Attempts How many times to poll before giving up
   --  @return The register's contents
   --  @exception Device_Misbehaved The device never reported the read done
   function Read_PHY
     (BAR      : Regions.Window;
      Number   : PHY_Register;
      Attempts : Positive := 20_000) return U16;

   --  Whether a physical-layer read reported an error rather than a value.
   --  @param BAR The device's mapped registers
   --  @return True when the last read set the error bit
   function PHY_Read_Failed (BAR : Regions.Window) return Boolean;

   --  Reads one word of the device's non-volatile configuration memory.
   --
   --  @param BAR The device's mapped registers
   --  @param Word Which sixteen-bit word
   --  @param Attempts How many times to poll before giving up
   --  @return The word's contents
   --  @exception Device_Misbehaved The device never reported the read done
   function Read_EEPROM
     (BAR      : Regions.Window;
      Word     : Natural;
      Attempts : Positive := 20_000) return U16;

   --  Where a descriptor ring lives, as both addresses of the same bytes.
   --
   --  @field Host Where this process writes and reads descriptors
   --  @field Device The address the controller is given
   --  @field Count How many descriptors the ring holds
   type Ring_Location is record
      Host   : System.Address;
      Device : U64;
      Count  : Positive;
   end record;

   --  Points the device at a receive ring and enables receiving.
   --
   --  Every descriptor is filled in with the address of its own buffer
   --  before the tail is advanced, because the device begins using them the
   --  moment it is told they are there.
   --
   --  @param BAR The device's mapped registers
   --  @param Ring Where the descriptor ring lives
   --  @param Buffers The device address of the first receive buffer
   --  @param Buffer_Bytes How large each buffer is
   procedure Start_Receiving
     (BAR          : Regions.Window;
      Ring         : Ring_Location;
      Buffers      : U64;
      Buffer_Bytes : Positive := Receive_Buffer_Bytes);

   --  Points the device at a transmit ring and enables transmitting.
   --  @param BAR The device's mapped registers
   --  @param Ring Where the descriptor ring lives
   procedure Start_Transmitting
     (BAR : Regions.Window; Ring : Ring_Location);

   --  Hands one frame to the device and waits for it to be taken.
   --
   --  The descriptor is written, then the tail register: a release store,
   --  because the descriptor must be visible to the device before the
   --  device is told the descriptor exists. Waiting for the done bit is
   --  waiting for the device to write into the driver's own memory.
   --
   --  @param BAR The device's mapped registers
   --  @param Ring Where the transmit ring lives
   --  @param Slot Which descriptor to use
   --  @param Frame The device address of the frame
   --  @param Length How many bytes the frame holds
   --  @param Attempts How many times to poll before giving up
   --  @exception Device_Misbehaved The device did not take the frame
   procedure Transmit
     (BAR      : Regions.Window;
      Ring     : Ring_Location;
      Slot     : Natural;
      Frame    : U64;
      Length   : Positive;
      Attempts : Positive := 20_000);

   --  What arrived in one receive descriptor.
   --
   --  @field Arrived Whether the device has finished with this descriptor
   --  @field Length How many bytes the frame holds
   --  @field Complete Whether the frame ends in this descriptor
   --  @field Errors The device's error byte, zero when the frame is sound
   type Received_Frame is record
      Arrived  : Boolean;
      Length   : Natural;
      Complete : Boolean;
      Errors   : U8;
   end record;

   --  Reads one receive descriptor without waiting.
   --  @param Ring Where the receive ring lives
   --  @param Slot Which descriptor to read
   --  @return What the device wrote there
   function Peek_Received
     (Ring : Ring_Location; Slot : Natural) return Received_Frame;

   --  Waits for a frame to arrive in one descriptor.
   --  @param Ring Where the receive ring lives
   --  @param Slot Which descriptor to watch
   --  @param Attempts How many times to poll before giving up
   --  @return What arrived
   --  @exception Device_Misbehaved Nothing arrived in time
   function Await_Received
     (Ring     : Ring_Location;
      Slot     : Natural;
      Attempts : Positive := 20_000) return Received_Frame;

   --  Gives a receive descriptor back to the device.
   --  @param BAR The device's mapped registers
   --  @param Ring Where the receive ring lives
   --  @param Slot Which descriptor is being returned
   --  @param Buffer The device address of its buffer
   procedure Recycle_Received
     (BAR    : Regions.Window;
      Ring   : Ring_Location;
      Slot   : Natural;
      Buffer : U64);

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
