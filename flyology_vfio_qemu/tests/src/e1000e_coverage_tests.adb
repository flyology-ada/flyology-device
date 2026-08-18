--  Measures how much of this controller's register surface is real.
--
--  A datasheet lists hundreds of registers. An emulator implements some of
--  them properly, some of them as a value that can be written and read
--  back, and some not at all — and which is which is not written down
--  anywhere a driver can consult. This program finds out by asking the
--  device, so that the answer comes from the device present rather than
--  from a reading of its source done once by hand.
--
--  Three sweeps, because the controller has three separate surfaces:
--
--  The memory-mapped registers, which are probed by reading them. A
--  register reading as all ones is one nothing answers; anything else is
--  present. That test is weaker than it looks — an implemented register
--  may legitimately hold all ones — so it is reported rather than asserted,
--  and the registers the functional test drives are checked by name.
--
--  The physical-layer chip, which is a second device reached through a
--  single register with a ready bit. Its first two registers are
--  standardised across every such chip ever made, so they can be checked
--  against the standard rather than against this device.
--
--  The non-volatile configuration memory, whose first three words hold the
--  hardware address. That gives the strongest check available here: the
--  address the device powers up with, read through a completely different
--  path from the receive address registers, must agree with them.

with Ada.Environment_Variables;
with Ada.Exceptions;
with Flyology_DMA;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Regions;
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.E1000E;
with Harness;
with Interfaces;

procedure E1000E_Coverage_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package NIC renames Flyology_VFIO_QEMU.E1000E;
   package Reg renames Flyology_VFIO.Registers;

   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type NIC.MAC_Address;

   --  One register of the datasheet, with the name it is known by.
   type Register_Description is record
      Offset    : DMA.Byte_Count;
      Name      : String (1 .. 26);
      Exercised : Boolean;
   end record;

   function Described
     (Offset : DMA.Byte_Count; Name : String; Exercised : Boolean := False)
      return Register_Description
   is
      Padded : String (1 .. 26) := (others => ' ');
   begin
      Padded (1 .. Name'Length) := Name;
      return (Offset, Padded, Exercised);
   end Described;

   type Register_List is array (Positive range <>) of Register_Description;

   --  The registers a driver for this controller actually touches. Those
   --  marked exercised are driven by e1000e_tests; the rest are here so
   --  that the report says how much of the surface is being left alone.
   Registers : constant Register_List :=
     [Described (16#00000#, "Device Control", True),
      Described (16#00008#, "Device Status", True),
      Described (16#00014#, "EEPROM Read", True),
      Described (16#00018#, "Extended Device Control", True),
      Described (16#00020#, "PHY Window", True),
      Described (16#000C0#, "Interrupt Cause Read", True),
      Described (16#000C8#, "Interrupt Cause Set", True),
      Described (16#000D0#, "Interrupt Mask Set", True),
      Described (16#000D8#, "Interrupt Mask Clear", True),
      Described (16#000E4#, "Interrupt Throttling", True),
      Described (16#00100#, "Receive Control", True),
      Described (16#00400#, "Transmit Control", True),
      Described (16#00410#, "Transmit Gap", True),
      Described (16#02800#, "Receive Ring Base Low", True),
      Described (16#02804#, "Receive Ring Base High", True),
      Described (16#02808#, "Receive Ring Length", True),
      Described (16#02810#, "Receive Ring Head", True),
      Described (16#02818#, "Receive Ring Tail", True),
      Described (16#02828#, "Receive Delay Timer"),
      Described (16#03800#, "Transmit Ring Base Low", True),
      Described (16#03804#, "Transmit Ring Base High", True),
      Described (16#03808#, "Transmit Ring Length", True),
      Described (16#03810#, "Transmit Ring Head", True),
      Described (16#03818#, "Transmit Ring Tail", True),
      Described (16#03820#, "Transmit Delay Timer"),
      Described (16#04000#, "CRC Error Count", True),
      Described (16#04074#, "Good Packets Received", True),
      Described (16#04080#, "Good Packets Sent", True),
      Described (16#040D0#, "Total Packets Received", True),
      Described (16#040D4#, "Total Packets Sent", True),
      Described (16#040C0#, "Total Octets Received", True),
      Described (16#040C8#, "Total Octets Sent", True),
      Described (16#04010#, "Missed Packet Count", True),
      Described (16#04030#, "Broadcast Received", True),
      Described (16#05000#, "Multicast Table Array"),
      Described (16#05038#, "VLAN Ethertype"),
      Described (16#05400#, "Receive Address Low", True),
      Described (16#05404#, "Receive Address High", True),
      Described (16#00028#, "Flow Control Address Low"),
      Described (16#0002C#, "Flow Control Address High"),
      Described (16#00030#, "Flow Control Type"),
      Described (16#05F00#, "Wake Up Control")];

   --  A register that answers nothing reads as every bit set, because
   --  nothing drives the bus low.
   Unimplemented : constant U32 := 16#FFFF_FFFF#;

   function Expected_MAC return String is
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_DEVICE_VM_MAC")
      then Ada.Environment_Variables.Value ("FLYOLOGY_DEVICE_VM_MAC")
      else "52:54:00:12:34:56");

   --  What the functional suite reached when this floor was last reviewed.
   Coverage_Floor : constant := 33;
begin
   declare
      Where : constant String := Find (NIC.Vendor_ID, NIC.Device_ID);
      Container : Container_FD;
      Group     : Group_FD;
      Device    : Device_FD;
   begin
      Harness.Note ("device at " & Where);

      Containers.Open (Container);
      Groups.Open (Group, Groups.Group_Of (Where));
      Groups.Attach (Group, Container);
      Containers.Set_IOMMU (Container);
      Devices.Open (Device, Group, Container, Where);
      Config.Enable_Memory_Space (Device);

      declare
         BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (BAR, Device, NIC.Register_BAR);

         ------------------------------------------------------------
         --  The memory-mapped registers
         ------------------------------------------------------------

         declare
            Present   : Natural := 0;
            Exercised : Natural := 0;
            Absent    : Natural := 0;
         begin
            Harness.Note ("");
            Harness.Note ("memory-mapped registers:");
            for Item of Registers loop
               if not Reg.Is_Valid_Access
                        (Device_Regions.Length (BAR), Item.Offset, 4)
               then
                  Harness.Note
                    ("  0x" & Hex_32 (U32 (Item.Offset)) & "  " & Item.Name
                     & "  outside the mapped window");
               else
                  declare
                     Value : constant U32 := Reg.Read_32 (BAR, Item.Offset);
                     Here  : constant Boolean := Value /= Unimplemented;
                  begin
                     if Here then
                        Present := Present + 1;
                        if Item.Exercised then
                           Exercised := Exercised + 1;
                        end if;
                     else
                        Absent := Absent + 1;
                     end if;
                     Harness.Note
                       ("  0x" & Hex_32 (U32 (Item.Offset)) & "  "
                        & Item.Name & "  "
                        & (if Here then "0x" & Hex_32 (Value)
                           else "no answer ")
                        & (if Here and then Item.Exercised
                           then "  exercised" else ""));
                  end;
               end if;
            end loop;

            Harness.Note ("");
            Harness.Note
              ("registers:" & Natural'Image (Exercised) & " of"
               & Natural'Image (Present) & " answered are exercised,"
               & Natural'Image (Absent) & " answered nothing");
            Harness.Check
              (Present > 0, "the register window answers at all");
            Harness.Check
              (Exercised >= Coverage_Floor,
               "the functional suite still drives at least"
               & Natural'Image (Coverage_Floor)
               & " of the registers this device answers");
         end;

         ------------------------------------------------------------
         --  The physical-layer chip behind the register window
         ------------------------------------------------------------

         declare
            Answered : Natural := 0;
         begin
            Harness.Note ("");
            Harness.Note ("physical-layer registers:");
            for Number in NIC.PHY_Register loop
               declare
                  Value : constant U16 := NIC.Read_PHY (BAR, Number);
               begin
                  if not NIC.PHY_Read_Failed (BAR) then
                     Answered := Answered + 1;
                     if Value /= 0 then
                        Harness.Note
                          ("  " & NIC.PHY_Register'Image (Number)
                           & "  0x" & Hex_16 (Value));
                     end if;
                  end if;
               end;
            end loop;
            Harness.Note
              ("  " & Natural'Image (Answered) & " of 32 answered");
            Harness.Check
              (Answered > 0,
               "the physical-layer chip answers through the register"
               & " window, which is a second bus reached through the"
               & " first");

            --  The first two registers are the same on every such chip
            --  ever made, which makes them checkable against the standard
            --  rather than against this device.
            declare
               Status : constant U16 := NIC.Read_PHY (BAR, NIC.PHY_Status);
               High   : constant U16 :=
                 NIC.Read_PHY (BAR, NIC.PHY_Identifier_High);
               Low    : constant U16 :=
                 NIC.Read_PHY (BAR, NIC.PHY_Identifier_Low);
            begin
               Harness.Note
                 ("  identity 0x" & Hex_16 (High) & Hex_16 (Low)
                  & ", status 0x" & Hex_16 (Status));
               Harness.Check
                 (Status /= 0 and then Status /= 16#FFFF#,
                  "its status register holds something, so the small bus"
                  & " behind the register window really carried a read");
               Harness.Check
                 ((High /= 0 or else Low /= 0)
                    and then not (High = 16#FFFF# and then Low = 16#FFFF#),
                  "it reports an identity, which every physical-layer chip"
                  & " must");
            end;
         end;

         ------------------------------------------------------------
         --  The non-volatile configuration memory
         ------------------------------------------------------------

         declare
            From_EEPROM : NIC.MAC_Address;
            From_Registers : constant NIC.MAC_Address :=
              NIC.Hardware_Address (BAR);
            Wanted : constant NIC.MAC_Address := NIC.Value (Expected_MAC);
         begin
            Harness.Note ("");
            Harness.Note ("configuration memory:");

            --  The first three words are the hardware address, two bytes
            --  at a time and least significant first.
            for Word in 0 .. 2 loop
               declare
                  Value : constant U16 := NIC.Read_EEPROM (BAR, Word);
               begin
                  Harness.Note
                    ("  word" & Natural'Image (Word) & "  0x"
                     & Hex_16 (Value));
                  From_EEPROM (Word * 2 + 1) := U8 (Value and 16#FF#);
                  From_EEPROM (Word * 2 + 2) :=
                    U8 (Interfaces.Shift_Right (Value, 8) and 16#FF#);
               end;
            end loop;

            Harness.Note
              ("  configuration memory holds "
               & NIC.Image (From_EEPROM));
            Harness.Note
              ("  the registers hold          "
               & NIC.Image (From_Registers));

            --  Three independent sources for one value: what the machine
            --  was started with, what the device's configuration memory
            --  holds, and what its receive address registers report. All
            --  three agreeing is a much stronger statement than any one of
            --  them being readable.
            Harness.Check
              (From_EEPROM = Wanted,
               "the configuration memory holds the address the virtual"
               & " machine was started with");
            Harness.Check
              (From_EEPROM = From_Registers,
               "and the receive address registers agree with it, having"
               & " been reached by a different path entirely");
         end;
      end;
   end;

   Harness.Report ("e1000e_coverage_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("the whole probe", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_coverage_tests");
end E1000E_Coverage_Tests;
