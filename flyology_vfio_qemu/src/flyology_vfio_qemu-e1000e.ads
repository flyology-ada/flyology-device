with Flyology_VFIO.Regions;
with Interfaces;
with System;
use type Interfaces.Unsigned_8;
use type Interfaces.Unsigned_16;
use type Interfaces.Unsigned_64;
use type Interfaces.Unsigned_32;

--  An Intel 82574L gigabit controller, as QEMU emulates it, driven as a
--  network interface.
--
--  This device is here first for its shape. It is the only thing in this
--  repository with more than one base address register, the only one with
--  a region the kernel decorates with a capability chain, and the only one
--  offering more than one interrupt vector. Those are three parts of
--  Flyology_VFIO that nothing else exercises.
--
--  It is then driven far enough to carry traffic: receive and transmit
--  descriptor rings in mapped memory, the link brought up, a frame sent and
--  a reply received. It also reaches two surfaces behind the register
--  window — the physical-layer chip, which is a second device on a small
--  bus with its own ready bit, and the non-volatile configuration memory
--  the device powers up from.
--
--  It offers the best corpus available in a virtual machine. Its receive
--  address registers hold a MAC address chosen on the command line that
--  started the machine, so a value picked outside this program can be
--  recovered through MMIO and compared — and recovered a second time, by a
--  different path, out of the configuration memory. A register window
--  reading plausible-looking rubbish fails that; a self-consistency check
--  would not.
--
--  What is deliberately not here: everything above a single frame. There is
--  no checksum or segmentation offload, no receive-side scaling, no VLAN
--  or multicast filtering, no flow control, and no interrupt-driven
--  receive — the rings are polled. Those are a network driver, and this is
--  a harness.
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

   ---------------------------------------------------------------------
   --  Deciding which frames to keep
   ---------------------------------------------------------------------

   --  A network controller spends most of its life refusing frames. On a
   --  shared medium nearly everything it sees belongs to someone else, and
   --  the filter is what keeps the host from being told about all of it.
   --  Every register below is part of that decision.

   --  Which tag protocol identifies a VLAN header. Set to 8100h for the
   --  ordinary case; a device with the wrong value here sees tagged frames
   --  as untagged ones with peculiar contents.
   VLAN_Ether_Type_Register : constant := 16#00038#;

   --  A four-thousand-and-ninety-six bit vector, one bit per multicast
   --  address hash, spread over a hundred and twenty-eight registers.
   Multicast_Table_Register : constant := 16#05200#;

   --  How many registers the multicast table occupies.
   Multicast_Table_Entries : constant := 128;

   --  The same shape again, one bit per VLAN identifier.
   VLAN_Filter_Table_Register : constant := 16#05600#;

   --  How many registers the VLAN filter table occupies.
   VLAN_Filter_Entries : constant := 128;

   --  Whether to check the checksums of arriving frames, and where to
   --  start.
   Receive_Checksum_Register : constant := 16#05000#;

   --  The largest frame the device will accept once long packets are
   --  allowed. Without this a device with long packets enabled still drops
   --  anything past its default.
   Receive_Packet_Length_Register : constant := 16#05004#;

   --  Set in the control register to have the device understand VLAN tags:
   --  strip them from arriving frames into the descriptor, and insert them
   --  into departing ones that ask.
   Control_VLAN_Mode : constant U32 := 2 ** 30;

   --  Set in the receive control register to keep every unicast frame
   --  whatever its address. What a packet capture turns on and what a
   --  driver should not.
   Receive_Unicast_Promiscuous : constant U32 := 2 ** 3;

   --  Set to keep every multicast frame without consulting the table.
   Receive_Multicast_Promiscuous : constant U32 := 2 ** 4;

   --  Set to accept frames longer than the standard maximum.
   Receive_Long_Packets : constant U32 := 2 ** 5;

   --  Set to consult the VLAN filter table. Clear, every tagged frame is
   --  kept whatever its identifier, which is a filter that is switched off
   --  rather than one that is refusing.
   Receive_VLAN_Filter : constant U32 := 2 ** 18;

   --  Which bits of a multicast address the hash is taken from.
   --
   --  Four choices, each shifting the twelve-bit window down the address by
   --  a little. It exists so that two controllers sharing a medium can
   --  disagree about which addresses collide.
   --
   --  @enum From_Bit_47 The highest twelve bits of the address
   --  @enum From_Bit_46 One lower
   --  @enum From_Bit_45 Two lower
   --  @enum From_Bit_43 Four lower
   type Multicast_Offset is
     (From_Bit_47, From_Bit_46, From_Bit_45, From_Bit_43);

   --  Puts a multicast offset in the receive control register's field.
   --  @param Offset Which window to hash from
   --  @return The bits to set
   function Multicast_Offset_Bits (Offset : Multicast_Offset) return U32
     is (Interfaces.Shift_Left (U32 (Multicast_Offset'Pos (Offset)), 12));

   --  Set in the receive checksum register to check IP header checksums.
   Checksum_Offload_IP : constant U32 := 2 ** 8;

   --  Set to check TCP and UDP checksums.
   Checksum_Offload_Transport : constant U32 := 2 ** 9;

   --  Set in a receive descriptor's status when the frame carried a VLAN
   --  tag, which the device has moved into the descriptor.
   Descriptor_VLAN_Present : constant U8 := 2 ** 3;

   --  Set when the device checked the transport checksum. Its verdict is in
   --  the error byte, and reading that verdict without checking this first
   --  is reading a field the device never wrote.
   Descriptor_Transport_Checked : constant U8 := 2 ** 5;

   --  Set when the device checked the IP header checksum.
   Descriptor_IP_Checked : constant U8 := 2 ** 6;

   --  Set when the frame reached the host through the hash filter rather
   --  than an exact address match, so it may not be for this host at all:
   --  the hash is lossy and the driver has to check again.
   Descriptor_Inexact_Filter : constant U8 := 2 ** 7;

   --  Set in a receive descriptor's errors when the transport checksum was
   --  wrong.
   Descriptor_Transport_Checksum_Error : constant U8 := 2 ** 5;

   --  Set when the IP header checksum was wrong.
   Descriptor_IP_Checksum_Error : constant U8 := 2 ** 6;

   --  Set in a transmit descriptor's command to have the device compute and
   --  insert a checksum.
   Transmit_Insert_Checksum : constant U8 := 2 ** 2;

   --  Set to have the device insert the descriptor's tag into the frame.
   Transmit_Insert_VLAN : constant U8 := 2 ** 6;

   --  Set in the receive control register to read the buffer size field on
   --  a larger scale, which is how the field names sizes it has no room to
   --  encode.
   Receive_Buffer_Extend : constant U32 := 2 ** 25;

   --  How to say a receive buffer size in the receive control register.
   --
   --  Two bits name four sizes, and a third bit changes which four. The
   --  small sizes and the large ones therefore share encodings, so the same
   --  two bits mean two hundred and fifty-six bytes or sixteen kibibytes
   --  depending on a bit nine places away.
   --
   --  @param Bytes How large each buffer is
   --  @return The bits to set, extension bit included
   --  @exception Device_Misbehaved The size is not one the field can name
   function Receive_Buffer_Size_Bits (Bytes : Positive) return U32;

   --  A VLAN identifier: twelve bits of the tag, and the only part of it
   --  the filter looks at.
   type VLAN_Identifier is new Natural range 0 .. 4_095;

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

   --  What the device should do to a frame on its way out.
   --
   --  Both of these have the device do work the host would otherwise do
   --  itself, and both are places a driver can be wrong in a way that shows
   --  up only on the wire: the frame leaves looking right to the code that
   --  built it.
   --
   --  @field Insert_Checksum Have the device compute a checksum and write
   --    it into the frame
   --  @field Checksum_Start The first byte the sum covers
   --  @field Checksum_Offset Where in the frame to write the result
   --  @field Insert_VLAN Have the device add a VLAN tag
   --  @field VLAN_Tag The tag to add
   type Transmit_Options is record
      Insert_Checksum : Boolean := False;
      Checksum_Start  : Natural := 0;
      Checksum_Offset : Natural := 0;
      Insert_VLAN     : Boolean := False;
      VLAN_Tag        : U16     := 0;
   end record;

   --  Hands one frame to the device, asking it to finish the frame off.
   --
   --  @param BAR The device's mapped registers
   --  @param Ring Where the transmit ring lives
   --  @param Slot Which descriptor to use
   --  @param Frame The device address of the frame
   --  @param Length How many bytes the frame holds
   --  @param Options What the device should do to it
   --  @param Attempts How many times to poll before giving up
   --  @exception Device_Misbehaved The device did not take the frame
   procedure Transmit
     (BAR      : Regions.Window;
      Ring     : Ring_Location;
      Slot     : Natural;
      Frame    : U64;
      Length   : Positive;
      Options  : Transmit_Options;
      Attempts : Positive := 20_000);

   --  Turns off every multicast address the device was keeping.
   --  @param BAR The device's mapped registers
   procedure Clear_Multicast_Table (BAR : Regions.Window);

   --  Which bit of the multicast table an address falls on.
   --
   --  The hash is lossy by design: four thousand and ninety-six bits stand
   --  for every multicast address there is, so addresses collide and a
   --  driver allowing one may find it is receiving another. That is what
   --  the inexact-filter bit in the descriptor is for.
   --
   --  @param Address The multicast address
   --  @param Offset Which window to hash from
   --  @return The bit, from zero
   function Multicast_Bit
     (Address : MAC_Address;
      Offset  : Multicast_Offset := From_Bit_47) return Natural;

   --  Starts or stops keeping frames for one multicast address.
   --  @param BAR The device's mapped registers
   --  @param Address The multicast address
   --  @param Allowed Whether to keep frames for it
   --  @param Offset Which window to hash from
   procedure Set_Multicast
     (BAR     : Regions.Window;
      Address : MAC_Address;
      Allowed : Boolean;
      Offset  : Multicast_Offset := From_Bit_47);

   --  Turns off every VLAN the device was keeping.
   --  @param BAR The device's mapped registers
   procedure Clear_VLAN_Filters (BAR : Regions.Window);

   --  Starts or stops keeping frames tagged with one VLAN.
   --  @param BAR The device's mapped registers
   --  @param Identifier Which VLAN
   --  @param Allowed Whether to keep its frames
   procedure Set_VLAN_Filter
     (BAR        : Regions.Window;
      Identifier : VLAN_Identifier;
      Allowed    : Boolean);

   --  Whether the device is currently keeping frames for one VLAN.
   --  @param BAR The device's mapped registers
   --  @param Identifier Which VLAN
   --  @return True when its frames are kept
   function VLAN_Filter_Allows
     (BAR : Regions.Window; Identifier : VLAN_Identifier) return Boolean;

   --  What arrived in one receive descriptor.
   --
   --  @field Arrived Whether the device has finished with this descriptor
   --  @field Length How many bytes the frame holds
   --  @field Complete Whether the frame ends in this descriptor
   --  @field Errors The device's error byte, zero when the frame is sound
   --  @field Status The device's whole status byte
   --  @field VLAN_Tag The tag the device stripped, when Status says there
   --    was one
   --  @field Checksum The frame checksum the device computed
   type Received_Frame is record
      Arrived  : Boolean;
      Length   : Natural;
      Complete : Boolean;
      Errors   : U8;
      Status   : U8  := 0;
      VLAN_Tag : U16 := 0;
      Checksum : U16 := 0;
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
