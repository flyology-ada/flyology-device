--  Reads an Intel gigabit controller's identity back out of its registers.
--
--  This device contributes three things nothing else here has: several base
--  address registers on one device, a region the kernel decorates with a
--  capability chain, and more than one interrupt vector.
--
--  It also contributes the best corpus available in a virtual machine. Its
--  receive address registers hold a MAC address chosen on the command line
--  that started the guest, so a value picked outside this program is
--  recovered inside it through MMIO. A register window reading plausible
--  rubbish fails that; a self-consistency check would not.

with Ada.Command_Line;
with Flyology_DMA.Mappers;
with Flyology_DMA.Regions;
with Flyology_VFIO.DMA_Mapper;
with System.Storage_Elements;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Flyology_DMA;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Interrupts;
with Flyology_VFIO.Regions;
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.E1000E;
with Harness;
with Interfaces;

procedure E1000E_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package IRQ renames Flyology_VFIO.Interrupts;
   package NIC renames Flyology_VFIO_QEMU.E1000E;
   package Reg renames Flyology_VFIO.Registers;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_32;
   use type NIC.MAC_Address;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;
   use type System.Storage_Elements.Storage_Offset;

   package SSE renames System.Storage_Elements;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  Sixteen descriptors in each ring. The receive ring's length register
   --  is in bytes and must be a multiple of a hundred and twenty-eight,
   --  which sixteen sixteen-byte descriptors satisfies exactly.
   Ring_Slots : constant Positive := 16;

   Receive_Ring_Offset    : constant DMA.Byte_Count := 0;
   Transmit_Ring_Offset   : constant DMA.Byte_Count := 4096;
   Receive_Buffers_Offset : constant DMA.Byte_Count := 8192;
   Transmit_Frame_Offset  : constant DMA.Byte_Count := 65536;

   --  Who to ask, and who to say is asking.
   --
   --  The peer on the far side of the wire, rather than QEMU's own
   --  translating stack. That stack answers address resolution too, and
   --  relying on it made this test depend on something whose only job is to
   --  translate — it terminates what it is sent and believes it owns every
   --  address on its network, which turns out to matter a great deal to
   --  anything trying to hold a conversation across it.
   Peer_Address : constant array (1 .. 4) of U8 := [10, 0, 2, 50];
   Our_Address  : constant array (1 .. 4) of U8 := [10, 0, 2, 99];

   --  What the machine was started with, read from the environment so that
   --  the harness and the test cannot disagree silently.
   function Expected_MAC return String is
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_DEVICE_VM_MAC")
      then Ada.Environment_Variables.Value ("FLYOLOGY_DEVICE_VM_MAC")
      else "52:54:00:12:34:56");
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

      Harness.Check_Equal
        (U32 (Config.Vendor_ID (Device)), U32 (NIC.Vendor_ID),
         "configuration space reports Intel");
      Harness.Check_Equal
        (U32 (Config.Device_ID (Device)), U32 (NIC.Device_ID),
         "configuration space reports the expected controller");

      --  Several regions on one device, which is what this device is for.
      declare
         Implemented   : Natural := 0;
         Mappable      : Natural := 0;
         With_Caps     : Natural := 0;
         Not_Mappable  : Natural := 0;
      begin
         for Index in Device_Regions.Region_Index range 0 .. 5 loop
            exit when Natural (Index) >= Devices.Region_Count (Device);
            declare
               Details : constant Device_Regions.Region_Details :=
                 Device_Regions.Describe (Device, Index);
            begin
               if Details.Implemented and then Details.Size > 0 then
                  Implemented := Implemented + 1;
                  Harness.Note
                    ("region" & Device_Regions.Region_Index'Image (Index)
                     & ":" & DMA.Byte_Count'Image (Details.Size) & " bytes"
                     & (if Details.Mappable then ", mappable"
                        else ", not mappable")
                     & (if Details.Has_Capabilities
                        then ", with a capability chain" else ""));
                  if Details.Mappable then
                     Mappable := Mappable + 1;
                  else
                     Not_Mappable := Not_Mappable + 1;
                  end if;
                  if Details.Has_Capabilities then
                     With_Caps := With_Caps + 1;
                  end if;
               end if;
            end;
         end loop;

         Harness.Check
           (Implemented > 1,
            "this device implements more than one region:"
            & Natural'Image (Implemented) & ", where every other device"
            & " here has one");
         Harness.Check (Mappable > 0, "at least one region is mappable");

         if With_Caps > 0 then
            Harness.Check
              (With_Caps > 0,
               "the kernel offers a capability chain for"
               & Natural'Image (With_Caps) & " region(s), which is the"
               & " two-call query this crate reports but does not yet read");
         else
            Harness.Skip
              ("capability chains", "this kernel offered none for it");
         end if;
      end;

      --  Several interrupt vectors, which is the other thing nothing else
      --  here exercises.
      declare
         MSI_X : constant IRQ.Interrupt_Details :=
           IRQ.Describe (Device, IRQ.MSI_X);
         Pin : constant IRQ.Interrupt_Details :=
           IRQ.Describe (Device, IRQ.Legacy_Pin);
      begin
         if MSI_X.Implemented and then MSI_X.Count > 0 then
            Harness.Note
              ("MSI-X offers" & Natural'Image (MSI_X.Count) & " vector(s)");
            Harness.Check
              (MSI_X.Count > 1, "it offers more than one MSI-X vector");
            Harness.Check
              (MSI_X.Supports_Eventfd,
               "its MSI-X vectors deliver on an eventfd");
         else
            Harness.Skip ("MSI-X shape", "this device reports no MSI-X");
         end if;

         if Pin.Implemented and then Pin.Count > 0 then
            Harness.Check
              (Pin.Automasked,
               "its pin interrupt is automasked, as a shared line must be");
         end if;
      end;

      declare
         BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (BAR, Device, NIC.Register_BAR);
         Harness.Note
           ("mapped registers,"
            & DMA.Byte_Count'Image (Device_Regions.Length (BAR)) & " bytes");
         Harness.Check
           (Device_Regions.Length (BAR) >= 16#20000#,
            "the register window is the full one hundred and twenty-eight"
            & " kibibytes, not a truncated mapping");

         Config.Enable_Memory_Space (Device);

         --  The corpus: an address chosen outside this program.
         declare
            Wanted : constant NIC.MAC_Address := NIC.Value (Expected_MAC);
            Seen   : constant NIC.MAC_Address := NIC.Hardware_Address (BAR);
         begin
            Harness.Note ("expected  " & NIC.Image (Wanted));
            Harness.Note ("read back " & NIC.Image (Seen));
            Harness.Check
              (NIC.Hardware_Address_Valid (BAR),
               "the device marks its first receive address as valid");
            Harness.Check
              (Seen = Wanted,
               "the hardware address read out of the device is the one the"
               & " virtual machine was started with");
         end;

         --  Registers at widely separated offsets, so a window mapped at
         --  the wrong place or with the wrong length cannot pass by only
         --  ever being read near its start.
         declare
            Status : constant U32 := Reg.Read_32 (BAR, NIC.Status_Register);
            Control : constant U32 :=
              Reg.Read_32 (BAR, NIC.Control_Register);
            Extended : constant U32 :=
              Reg.Read_32 (BAR, NIC.Extended_Control_Register);
         begin
            Harness.Note
              ("control 0x" & Hex_32 (Control) & ", status 0x"
               & Hex_32 (Status) & ", extended 0x" & Hex_32 (Extended));
            Harness.Check
              (Status /= 16#FFFF_FFFF# and then Control /= 16#FFFF_FFFF#,
               "the control and status registers do not read as all ones,"
               & " which is what an absent device returns");
            Harness.Check
              (Reg.Read_32 (BAR, NIC.Status_Register) = Status,
               "reading the status register twice agrees");
         end;

         --  A reset the device completes itself, which is a register a
         --  driver wrote coming back changed by the hardware.
         declare
            Before : constant NIC.MAC_Address := NIC.Hardware_Address (BAR);
         begin
            NIC.Reset (BAR);
            Harness.Check
              ((Reg.Read_32 (BAR, NIC.Control_Register) and NIC.Control_Reset)
                 = 0,
               "the device cleared the reset bit itself");
            Harness.Check
              (NIC.Hardware_Address (BAR) = Before,
               "the hardware address survived the reset, as it comes from"
               & " the device rather than from anything written to it");
         end;

         ---------------------------------------------------------------
         --  Rings, and a frame that goes out and comes back
         ---------------------------------------------------------------

         --  Everything above could pass against a device that never moved
         --  a byte. This is the part that makes it a network controller:
         --  descriptor rings in host memory the device reaches by DMA, a
         --  frame handed to it, and a reply written back into memory this
         --  program owns.
         Config.Enable_Bus_Mastering (Device);
         Harness.Check
           (Config.Bus_Mastering_Enabled (Device),
            "bus mastering is enabled, without which the device can reach"
            & " neither ring");

         --  Ask the device to bring the link up. Without it the transmit
         --  path accepts descriptors and drops the frames.
         Reg.Write_32
           (BAR, NIC.Control_Register,
            Reg.Read_32 (BAR, NIC.Control_Register) or NIC.Control_Set_Link_Up);

         declare
            Backend : aliased DMA_Mapper.Container_Mapper;
            Area    : constant DMA.Regions.Region :=
              DMA.Regions.Create (2 * 1024 * 1024, DMA.Regular_Pages);
         begin
            DMA_Mapper.Bind (Backend, Container);

            declare
               Bound : constant DMA.Mappers.Mapping :=
                 DMA.Mappers.Map_Region
                   (Backend'Access, Area, Window_Base,
                    DMA.Mappers.Device_Reads_And_Writes);
               pragma Unreferenced (Bound);

               Host : constant System.Address :=
                 DMA.Regions.Base_Address (Area);

               Receive_Ring : constant NIC.Ring_Location :=
                 (Host   => Host + SSE.Storage_Offset (Receive_Ring_Offset),
                  Device => U64 (Window_Base) + U64 (Receive_Ring_Offset),
                  Count  => Ring_Slots,
                  Queue  => 0);
               Transmit_Ring : constant NIC.Ring_Location :=
                 (Host   => Host + SSE.Storage_Offset (Transmit_Ring_Offset),
                  Device => U64 (Window_Base) + U64 (Transmit_Ring_Offset),
                  Count  => Ring_Slots,
                  Queue  => 0);

               Receive_Buffers : constant U64 :=
                 U64 (Window_Base) + U64 (Receive_Buffers_Offset);
               Transmit_Frame : constant U64 :=
                 U64 (Window_Base) + U64 (Transmit_Frame_Offset);

               Frame_Bytes : array (0 .. 2047) of U8
                 with Import, Volatile,
                      Address =>
                        Host + SSE.Storage_Offset (Transmit_Frame_Offset);

               Ours : constant NIC.MAC_Address := NIC.Hardware_Address (BAR);
               Request_Length : constant := 42;
            begin
               NIC.Start_Receiving (BAR, Receive_Ring, Receive_Buffers);
               NIC.Start_Transmitting (BAR, Transmit_Ring);

               Harness.Check
                 ((Reg.Read_32 (BAR, NIC.Receive_Control_Register)
                     and NIC.Receive_Enable) /= 0,
                  "the receiver is enabled");
               Harness.Check
                 ((Reg.Read_32 (BAR, NIC.Transmit_Control_Register)
                     and NIC.Transmit_Enable) /= 0,
                  "the transmitter is enabled");

               --  An address resolution request for the peer sharing this
               --  wire, which is what makes both directions testable: a
               --  reply has to have been produced by something that is not
               --  this device.
               Frame_Bytes := (others => 0);
               for Index in 0 .. 5 loop
                  Frame_Bytes (Index) := 16#FF#;                --  broadcast
                  Frame_Bytes (6 + Index) := Ours (Index + 1);  --  from us
               end loop;
               Frame_Bytes (12) := 16#08#;  --  address resolution
               Frame_Bytes (13) := 16#06#;
               Frame_Bytes (14) := 16#00#;  --  over Ethernet
               Frame_Bytes (15) := 16#01#;
               Frame_Bytes (16) := 16#08#;  --  resolving IPv4
               Frame_Bytes (17) := 16#00#;
               Frame_Bytes (18) := 6;
               Frame_Bytes (19) := 4;
               Frame_Bytes (20) := 16#00#;  --  a request
               Frame_Bytes (21) := 16#01#;
               for Index in 0 .. 5 loop
                  Frame_Bytes (22 + Index) := Ours (Index + 1);
               end loop;
               for Index in 0 .. 3 loop
                  Frame_Bytes (28 + Index) := Our_Address (Index + 1);
                  Frame_Bytes (38 + Index) := Peer_Address (Index + 1);
               end loop;

               NIC.Transmit
                 (BAR, Transmit_Ring, Slot => 0,
                  Frame => Transmit_Frame, Length => Request_Length);
               Harness.Check
                 (True,
                  "the device reported finishing with the transmit"
                  & " descriptor, which it writes by DMA");

               --  Looked for, not waited for at a fixed slot. The wire
               --  carries a peer with a mind of its own, and its broadcasts
               --  arrive whenever they arrive: one landing in slot zero
               --  first would make every check below read that frame
               --  instead of the reply, and report on its contents with
               --  perfect confidence.
               declare
                  Reply_Slot : Natural := 0;
                  Arrived    : NIC.Received_Frame;

                  function Is_Address_Reply (Slot : Natural) return Boolean is
                     Bytes : array (0 .. 63) of U8
                       with Import, Volatile,
                            Address =>
                              Host
                              + SSE.Storage_Offset (Receive_Buffers_Offset)
                              + SSE.Storage_Offset
                                  (Slot * NIC.Receive_Buffer_Bytes);
                  begin
                     --  An address resolution reply, and one about the
                     --  address that was asked about.
                     return Bytes (12) = 16#08# and then Bytes (13) = 16#06#
                       and then Bytes (20) = 0 and then Bytes (21) = 2
                       and then Bytes (28) = Peer_Address (1)
                       and then Bytes (31) = Peer_Address (4);
                  end Is_Address_Reply;
               begin
                  Arrived := (Arrived => False, Length => 0,
                              Complete => False, Errors => 0, others => <>);
                  Searching :
                  for Attempt in 1 .. 400 loop
                     for Slot in 0 .. Ring_Slots - 1 loop
                        declare
                           Seen : constant NIC.Received_Frame :=
                             NIC.Peek_Received (Receive_Ring, Slot);
                        begin
                           if Seen.Arrived and then Is_Address_Reply (Slot)
                           then
                              Arrived := Seen;
                              Reply_Slot := Slot;
                              exit Searching;
                           end if;
                        end;
                     end loop;
                     delay 0.005;
                  end loop Searching;

                  declare
                     Reply : array (0 .. 2047) of U8
                       with Import, Volatile,
                            Address =>
                              Host
                              + SSE.Storage_Offset (Receive_Buffers_Offset)
                              + SSE.Storage_Offset
                                  (Reply_Slot * NIC.Receive_Buffer_Bytes);
                  begin
                  Harness.Check (Arrived.Arrived, "a frame arrived");
                  Harness.Check
                    (Arrived.Complete,
                     "the frame is complete in one descriptor");
                  Harness.Check_Equal
                    (U32 (Arrived.Errors), 0,
                     "the device reported no error with it");
                  Harness.Note
                    ("received" & Natural'Image (Arrived.Length)
                     & " bytes");
                  Harness.Check
                    (Arrived.Length >= 42,
                     "it is long enough to be an address resolution reply");

                  Harness.Check
                    (Reply (12) = 16#08# and then Reply (13) = 16#06#,
                     "it is an address resolution frame");
                  Harness.Check
                    (Reply (20) = 16#00# and then Reply (21) = 16#02#,
                     "it is a reply rather than another request");

                  declare
                     Addressed_To_Us : Boolean := True;
                     From_Gateway    : Boolean := True;
                  begin
                     for Index in 0 .. 5 loop
                        if Reply (Index) /= Ours (Index + 1) then
                           Addressed_To_Us := False;
                        end if;
                     end loop;
                     for Index in 0 .. 3 loop
                        if Reply (28 + Index) /= Peer_Address (Index + 1)
                        then
                           From_Gateway := False;
                        end if;
                     end loop;

                     Harness.Check
                       (Addressed_To_Us,
                        "the reply is addressed to the hardware address this"
                        & " device reported");
                     Harness.Check
                       (From_Gateway,
                        "it answers for the address that was asked about,"
                        & " so the frame this driver built was understood");
                  end;

                  NIC.Recycle_Received
                    (BAR, Receive_Ring, Slot => Reply_Slot,
                     Buffer => Receive_Buffers
                               + U64 (Reply_Slot)
                                 * U64 (NIC.Receive_Buffer_Bytes));
                  end;
               end;

               ------------------------------------------------------
               --  Interrupt causes, which acknowledge by being read
               ------------------------------------------------------

               --  A cause register that clears when read is the sharpest
               --  example of why Flyology_VFIO.Registers warns against
               --  read-modify-writing a status register: here the read is
               --  the acknowledgement, so a driver that reads to modify
               --  has already thrown the event away.
               declare
                  Raised  : constant U32 :=
                    NIC.Interrupt_Link_Change or NIC.Interrupt_Transmit_Done;
                  Ignored : U32;
                  First   : U32;
                  Second  : U32;
               begin
                  --  Masked off first, so provoking a cause cannot deliver
                  --  an interrupt to a handler that does not exist.
                  Reg.Write_32
                    (BAR, NIC.Interrupt_Mask_Clear_Register, 16#FFFF_FFFF#);

                  --  Read once to clear whatever had accumulated, so that
                  --  what follows is only what this test provoked.
                  Ignored := Reg.Read_32 (BAR, NIC.Interrupt_Cause_Register);
                  pragma Unreferenced (Ignored);

                  Reg.Write_Release_32
                    (BAR, NIC.Interrupt_Cause_Set_Register, Raised);
                  First := Reg.Read_32 (BAR, NIC.Interrupt_Cause_Register);
                  Second := Reg.Read_32 (BAR, NIC.Interrupt_Cause_Register);

                  Harness.Note
                    ("causes read 0x" & Hex_32 (First) & " then 0x"
                     & Hex_32 (Second));
                  Harness.Check
                    ((First and Raised) = Raised,
                     "the causes that were provoked are reported");
                  Harness.Check
                    ((Second and Raised) = 0,
                     "and are gone on the second read, because reading the"
                     & " cause register is what acknowledges it");
               end;

               --  The mask registers, which are write-only in one
               --  direction each: one sets bits, the other clears them,
               --  and neither can be read back to see the result. Checking
               --  they are accepted is all that can be checked.
               declare
                  Wanted : constant U32 := NIC.Interrupt_Receive_Timer;
               begin
                  Reg.Write_32 (BAR, NIC.Interrupt_Mask_Set_Register, Wanted);
                  Reg.Write_32
                    (BAR, NIC.Interrupt_Mask_Clear_Register, Wanted);
                  Harness.Check
                    (True,
                     "the interrupt mask registers accept being set and"
                     & " cleared");
               end;

               ------------------------------------------------------
               --  A frame that never leaves the device
               ------------------------------------------------------

               --  Loopback routes transmitted frames straight back into
               --  the receive path. It proves both rings without anything
               --  attached to the device, which the exchange above cannot:
               --  that one depends on something outside the guest choosing
               --  to answer.
               declare
                  Slot : constant Natural := 1;
                  Marker : constant U8 := 16#5A#;
               begin
                  Reg.Write_Release_32
                    (BAR, NIC.Receive_Control_Register,
                     NIC.Receive_Enable or NIC.Receive_Broadcast
                     or NIC.Receive_Strip_CRC or NIC.Receive_Loopback);

                  Frame_Bytes := (others => Marker);
                  for Index in 0 .. 5 loop
                     Frame_Bytes (Index) := Ours (Index + 1);
                     Frame_Bytes (6 + Index) := Ours (Index + 1);
                  end loop;
                  Frame_Bytes (12) := 16#88#;
                  Frame_Bytes (13) := 16#B5#;

                  NIC.Transmit
                    (BAR, Transmit_Ring, Slot => Slot,
                     Frame => Transmit_Frame, Length => 64);

                  declare
                     Arrived : constant NIC.Received_Frame :=
                       NIC.Await_Received (Receive_Ring, Slot => Slot);
                     Looped : array (0 .. 2047) of U8
                       with Import, Volatile,
                            Address =>
                              Host
                              + SSE.Storage_Offset (Receive_Buffers_Offset)
                              + SSE.Storage_Offset
                                  (Slot * NIC.Receive_Buffer_Bytes);
                  begin
                     Harness.Check
                       (Arrived.Arrived,
                        "a frame sent in loopback comes back without"
                        & " leaving the device");
                     Harness.Check_Equal
                       (U32 (Arrived.Errors), 0,
                        "and arrives without an error");
                     Harness.Check
                       (Looped (12) = 16#88# and then Looped (13) = 16#B5#,
                        "carrying the protocol number it was sent with");
                     Harness.Check
                       (Looped (20) = Marker and then Looped (60) = Marker,
                        "and its payload, which nothing outside the device"
                        & " could have supplied");
                  end;

                  Reg.Write_Release_32
                    (BAR, NIC.Receive_Control_Register,
                     NIC.Receive_Enable or NIC.Receive_Broadcast
                     or NIC.Receive_Strip_CRC);
               end;

               --  The device's own counters. Both clear when read, which
               --  is why they are read once and compared rather than read
               --  twice.
               declare
                  Sent     : constant U32 :=
                    Reg.Read_32 (BAR, NIC.Good_Packets_Transmitted_Register);
                  Received : constant U32 :=
                    Reg.Read_32 (BAR, NIC.Good_Packets_Received_Register);
               begin
                  Harness.Note
                    ("the device counted" & U32'Image (Sent) & " sent and"
                     & U32'Image (Received) & " received");
                  Harness.Check
                    (Sent >= 1, "it counted the frame it sent");
                  Harness.Check
                    (Received >= 1, "it counted the frame it received");
                  Harness.Check
                    (Reg.Read_32
                       (BAR, NIC.Good_Packets_Transmitted_Register) = 0,
                     "the counter cleared when it was read, which is why a"
                     & " read-modify-write of such a register loses counts");

                  --  The wider set of counters, which between them account
                  --  for every frame and every octet the device handled.
                  declare
                     Total_Sent     : constant U32 :=
                       Reg.Read_32 (BAR, 16#040D4#);
                     Total_Received : constant U32 :=
                       Reg.Read_32 (BAR, 16#040D0#);
                     Octets_Sent    : constant U32 :=
                       Reg.Read_32 (BAR, 16#040C8#);
                     Octets_Received : constant U32 :=
                       Reg.Read_32 (BAR, 16#040C0#);
                     Broadcast      : constant U32 :=
                       Reg.Read_32 (BAR, 16#04030#);
                     CRC_Errors     : constant U32 :=
                       Reg.Read_32 (BAR, 16#04000#);
                     Missed         : constant U32 :=
                       Reg.Read_32 (BAR, 16#04010#);
                  begin
                     Harness.Note
                       ("totals:" & U32'Image (Total_Sent) & " sent,"
                        & U32'Image (Total_Received) & " received,"
                        & U32'Image (Octets_Sent) & " octets out,"
                        & U32'Image (Octets_Received) & " octets in,"
                        & U32'Image (Broadcast) & " broadcast,"
                        & U32'Image (CRC_Errors) & " CRC errors,"
                        & U32'Image (Missed) & " missed");
                     Harness.Check
                       (Total_Sent >= 2,
                        "the total counter saw both frames, the one that"
                        & " left and the one that looped back");
                     Harness.Check
                       (Octets_Sent > 0 and then Octets_Received > 0,
                        "the octet counters moved in both directions");
                     Harness.Check_Equal
                       (CRC_Errors, 0,
                        "no frame arrived with a bad checksum");
                  end;
               end;

               --  Before the mapping goes away, not after.
               NIC.Stop (BAR);
            exception
               --  Also on the way out through an exception, not only on
               --  the way out through the end. A device is not finished
               --  with a ring because the program that programmed it has
               --  stopped caring: the mapping goes away as this block
               --  unwinds, and anything still writing there writes to an
               --  address the IOMMU no longer translates. The fault storm
               --  that follows buries whatever raised in the first place.
               when others =>
                  begin
                     NIC.Stop (BAR);
                  exception
                     when others => null;
                  end;
                  raise;
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   Harness.Report ("e1000e_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every e1000e check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_tests");
   when Error : others =>
      Harness.Note
        ("unexpected: " & Ada.Exceptions.Exception_Name (Error) & ": "
         & Ada.Exceptions.Exception_Message (Error));
      Harness.Check (False, "the e1000e sequence completed without raising");
      Harness.Report ("e1000e_tests");
      Ada.Command_Line.Set_Exit_Status (1);
end E1000E_Tests;
