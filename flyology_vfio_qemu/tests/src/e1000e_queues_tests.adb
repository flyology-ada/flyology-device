--  Two queues, and the device deciding which frame belongs on which.
--
--  A controller with one queue serialises every core in the machine behind
--  one ring, one tail register, and one interrupt. Several queues is how
--  that stops being true. Receive-side scaling is how the device decides
--  which queue a frame belongs on without the host having looked at it: it
--  hashes the addresses and ports and consults a table.
--
--  Testing that properly would mean computing the same hash the device
--  computes, over a key this test chose, and predicting the queue. That is
--  a worthwhile thing to check and a poor thing to check first, because a
--  disagreement tells you nothing about which half was wrong.
--
--  So the table is filled with a single queue instead. Every hash then
--  leads to the same entry and the destination is known without the hash
--  being known. What that establishes is the part underneath: that the
--  second ring exists, that its registers are where they are believed to
--  be, that the device consults the table at all, and that a frame put on
--  one queue does not also appear on the other.

with Ada.Exceptions;
with Flyology_DMA;
with Flyology_DMA.Mappers;
with Flyology_DMA.Regions;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.DMA_Mapper;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Regions;
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.E1000E;
with Harness;
with Interfaces;
with System;

procedure E1000E_Queues_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package NIC renames Flyology_VFIO_QEMU.E1000E;
   package Reg renames Flyology_VFIO.Registers;

   use type DMA.Byte_Count;
   use type DMA.IOVA_Address;
   use type NIC.Queue_Index;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   Ring_Slots   : constant := 16;
   Buffer_Bytes : constant := 2048;

   RX0_Ring_Offset : constant DMA.Byte_Count := 0;
   RX1_Ring_Offset : constant DMA.Byte_Count := 4096;
   TX0_Ring_Offset : constant DMA.Byte_Count := 8192;
   TX1_Ring_Offset : constant DMA.Byte_Count := 12288;
   Frame_Offset    : constant DMA.Byte_Count := 16384;
   RX0_Buffers     : constant DMA.Byte_Count := 20480;
   RX1_Buffers     : constant DMA.Byte_Count :=
     RX0_Buffers + Buffer_Bytes * Ring_Slots;
   Scratch_Bytes   : constant :=
     20480 + 2 * Buffer_Bytes * Ring_Slots;
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
      Config.Enable_Bus_Mastering (Device);

      declare
         BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (BAR, Device, NIC.Register_BAR);

         declare
            Backend : aliased DMA_Mapper.Container_Mapper;
            Area : constant DMA.Regions.Region :=
              DMA.Regions.Create (2 * 1024 * 1024, DMA.Regular_Pages);
         begin
            DMA_Mapper.Bind (Backend, Container);

            declare
               Bound : constant DMA.Mappers.Mapping :=
                 DMA.Mappers.Map_Region
                   (Backend'Access, Area, Window_Base,
                    DMA.Mappers.Device_Reads_And_Writes);
               --  Both addresses come from the mapping rather than being
               --  recomputed beside it. It knows its own extent, so an
               --  offset that would put a structure past the end of the
               --  region is refused here instead of becoming an address
               --  the device faults on.
               function At_Host
                 (Offset : DMA.Byte_Count; Extent : DMA.Byte_Count := 1)
                  return System.Address
               is (Bound.Host_At (Offset, Extent));

               function At_Device
                 (Offset : DMA.Byte_Count; Extent : DMA.Byte_Count := 1)
                  return Device_Address
               is (Bound.Device_At (Offset, Extent));

               Host : constant System.Address := Bound.Host_At (0);

               RX : constant array (NIC.Queue_Index) of NIC.Ring_Location :=
                 [0 => (Host   => At_Host (RX0_Ring_Offset),
                        Device => At_Device (RX0_Ring_Offset),
                        Count  => Ring_Slots,
                        Queue  => 0),
                  1 => (Host   => At_Host (RX1_Ring_Offset),
                        Device => At_Device (RX1_Ring_Offset),
                        Count  => Ring_Slots,
                        Queue  => 1)];
               TX : constant array (NIC.Queue_Index) of NIC.Ring_Location :=
                 [0 => (Host   => At_Host (TX0_Ring_Offset),
                        Device => At_Device (TX0_Ring_Offset),
                        Count  => Ring_Slots,
                        Queue  => 0),
                  1 => (Host   => At_Host (TX1_Ring_Offset),
                        Device => At_Device (TX1_Ring_Offset),
                        Count  => Ring_Slots,
                        Queue  => 1)];
               Buffers : constant array (NIC.Queue_Index) of DMA.Byte_Count :=
                 [0 => RX0_Buffers, 1 => RX1_Buffers];

               Everything : array (1 .. Scratch_Bytes) of U8
                 with Import, Volatile, Address => Host;
               Frame : array (0 .. 1023) of U8
                 with Import, Volatile, Address => At_Host (Frame_Offset);

               Mine : NIC.MAC_Address;
               Steered_Away : Boolean := True;
               RX_Slot : array (NIC.Queue_Index) of Natural := [0, 0];
               TX_Slot : array (NIC.Queue_Index) of Natural := [0, 0];

               procedure Put_16_At (Where : Natural; Value : U16);
               function Build (Port : U16) return Positive;
               procedure Send_And_Look
                 (Length : Positive;
                  From   : NIC.Queue_Index;
                  Landed : out NIC.Queue_Index;
                  Any    : out Boolean);

               procedure Put_16_At (Where : Natural; Value : U16) is
               begin
                  Frame (Where) := U8 (Interfaces.Shift_Right (Value, 8));
                  Frame (Where + 1) := U8 (Value and 16#FF#);
               end Put_16_At;

               --  An IPv4 frame, because the device hashes those and has
               --  nothing to hash in a frame of arbitrary bytes. The source
               --  port varies so that different calls produce different
               --  hashes, which matters only for the last part of this.
               function Build (Port : U16) return Positive is
                  IP_At    : constant := 14;
                  UDP_At   : constant := 34;
                  Data_At  : constant := 42;
                  Payload  : constant := 32;
                  Sum      : U32 := 0;
               begin
                  for Index in 0 .. Data_At + Payload - 1 loop
                     Frame (Index) := 0;
                  end loop;
                  for Index in 1 .. 6 loop
                     Frame (Index - 1) := Mine (Index);
                     Frame (5 + Index) := Mine (Index);
                  end loop;
                  Put_16_At (12, 16#0800#);

                  Frame (IP_At) := 16#45#;
                  Put_16_At (IP_At + 2, 20 + 8 + Payload);
                  Frame (IP_At + 8) := 64;
                  Frame (IP_At + 9) := 17;
                  Frame (IP_At + 12) := 10;
                  Frame (IP_At + 15) := 1;
                  Frame (IP_At + 16) := 10;
                  Frame (IP_At + 19) := 2;
                  for Index in 0 .. 9 loop
                     Sum := Sum
                       + Interfaces.Shift_Left
                           (U32 (Frame (IP_At + 2 * Index)), 8)
                       + U32 (Frame (IP_At + 2 * Index + 1));
                  end loop;
                  while Interfaces.Shift_Right (Sum, 16) /= 0 loop
                     Sum := (Sum and 16#FFFF#)
                            + Interfaces.Shift_Right (Sum, 16);
                  end loop;
                  Put_16_At (IP_At + 10, not U16 (Sum and 16#FFFF#));

                  Put_16_At (UDP_At, Port);
                  Put_16_At (UDP_At + 2, 4_097);
                  Put_16_At (UDP_At + 4, 8 + Payload);

                  for Index in 0 .. Payload - 1 loop
                     Frame (Data_At + Index) := U8 ((Index * 5 + 1) mod 251);
                  end loop;
                  return Data_At + Payload;
               end Build;

               procedure Send_And_Look
                 (Length : Positive;
                  From   : NIC.Queue_Index;
                  Landed : out NIC.Queue_Index;
                  Any    : out Boolean)
               is
                  Seen : NIC.Received_Frame;
               begin
                  Landed := 0;
                  Any := False;
                  NIC.Transmit
                    (BAR, TX (From), TX_Slot (From),
                     At_Device (Frame_Offset), Length);
                  TX_Slot (From) := (TX_Slot (From) + 1) mod Ring_Slots;

                  for Attempt in 1 .. 200 loop
                     for Queue in NIC.Queue_Index loop
                        Seen := NIC.Peek_Received (RX (Queue),
                                                   RX_Slot (Queue));
                        if Seen.Arrived then
                           Landed := Queue;
                           Any := True;
                        end if;
                     end loop;
                     exit when Any;
                     delay 0.001;
                  end loop;

                  if Any then
                     NIC.Recycle_Received
                       (BAR, RX (Landed), RX_Slot (Landed),
                        At_Device
                          (Buffers (Landed)
                           + DMA.Byte_Count
                               (RX_Slot (Landed) * Buffer_Bytes)));
                     RX_Slot (Landed) :=
                       (RX_Slot (Landed) + 1) mod Ring_Slots;
                  end if;
               end Send_And_Look;
            begin
               Everything := (others => 0);
               NIC.Reset (BAR);
               Mine := NIC.Hardware_Address (BAR);

               for Queue in NIC.Queue_Index loop
                  NIC.Start_Receiving
                    (BAR, RX (Queue), At_Device (Buffers (Queue)),
                     Buffer_Bytes);
                  NIC.Start_Transmitting (BAR, TX (Queue));
               end loop;

               Harness.Check
                 (Reg.Read_32
                    (BAR, Reg.Offset (NIC.Receive_Ring_Base (1)))
                  = U32 (RX (1).Device and 16#FFFF_FFFF#),
                  "the second receive ring's base register holds the"
                  & " address it was given, so there is a second ring and"
                  & " not an unimplemented offset reading back as itself");
               Harness.Check
                 (Reg.Read_32
                    (BAR, Reg.Offset (NIC.Transmit_Ring_Base (1)))
                  = U32 (TX (1).Device and 16#FFFF_FFFF#),
                  "and a second transmit ring");
               Harness.Check
                 (Reg.Read_32
                    (BAR, Reg.Offset (NIC.Receive_Ring_Base (0)))
                  /= Reg.Read_32
                       (BAR, Reg.Offset (NIC.Receive_Ring_Base (1))),
                  "the two receive rings are at different addresses, so"
                  & " the second set of registers is not an alias of the"
                  & " first");

               Reg.Write_32
                 (BAR, NIC.Receive_Control_Register,
                  NIC.Receive_Enable or NIC.Receive_Broadcast
                  or NIC.Receive_Strip_CRC or NIC.Receive_Loopback);

               NIC.Set_Hash_Key (BAR, 16#5A5A_1234#);
               Reg.Write_32
                 (BAR, NIC.Multiple_Queue_Register,
                  NIC.Multiple_Queue_Enable or NIC.Hash_Field_IPv4
                  or NIC.Hash_Field_IPv4_TCP);
               Harness.Check
                 ((Reg.Read_32 (BAR, NIC.Multiple_Queue_Register)
                   and NIC.Multiple_Queue_Enable) /= 0,
                  "the device accepts being told to hash arriving frames"
                  & " rather than sending them all to the first queue");

               ------------------------------------------------------
               --  Steering
               ------------------------------------------------------

               for Target in NIC.Queue_Index loop
                  NIC.Steer_Everything_To (BAR, Target);
                  declare
                     Length : constant Positive := Build (5_000);
                     Landed : NIC.Queue_Index;
                     Any    : Boolean;
                  begin
                     Send_And_Look (Length, From => 0,
                                    Landed => Landed, Any => Any);
                     Harness.Check
                       (Any,
                        "with the whole table pointing at queue"
                        & NIC.Queue_Index'Image (Target)
                        & " a frame arrives somewhere");
                     if Any then
                        if Landed = Target then
                           Harness.Check
                             (True,
                              "and it is queue"
                              & NIC.Queue_Index'Image (Target)
                              & ", so the device read the table");
                        else
                           Steered_Away := False;
                           Harness.Note
                             ("with the table pointing at queue"
                              & NIC.Queue_Index'Image (Target)
                              & " the frame landed on queue"
                              & NIC.Queue_Index'Image (Landed));
                        end if;
                     end if;
                  end;
               end loop;

               if not Steered_Away then
                  Harness.Skip
                    ("steering to the second queue",
                     "this device hashes frames that arrive from outside"
                     & " and not frames it sent itself, so nothing reaches"
                     & " the second queue over a loopback however the"
                     & " table is filled; e1000e_peer_tests sends from"
                     & " elsewhere and checks it there");
               end if;

               ------------------------------------------------------
               --  Sending from the second transmit queue
               ------------------------------------------------------

               NIC.Steer_Everything_To (BAR, 0);
               declare
                  Length : constant Positive := Build (5_001);
                  Landed : NIC.Queue_Index;
                  Any    : Boolean;
               begin
                  Send_And_Look (Length, From => 1,
                                 Landed => Landed, Any => Any);
                  Harness.Check
                    (Any and then Landed = 0,
                     "a frame handed to the second transmit queue goes out"
                     & " and comes back, so both transmit rings are wired"
                     & " to the same wire");
               end;

               ------------------------------------------------------
               --  Waiting before interrupting
               ------------------------------------------------------

               declare
                  type Timer is record
                     Where : Natural;
                     Name  : String (1 .. 26);
                     Value : U32;
                  end record;

                  function Named (Text : String) return String is
                     Room : String (1 .. 26) := [others => ' '];
                  begin
                     Room (1 .. Text'Length) := Text;
                     return Room;
                  end Named;

                  Timers : constant array (1 .. 5) of Timer :=
                    [(NIC.Receive_Delay_Register,
                      Named ("receive delay"), 16#0020#),
                     (NIC.Receive_Absolute_Delay_Register,
                      Named ("receive absolute delay"), 16#0040#),
                     (NIC.Transmit_Delay_Register,
                      Named ("transmit delay"), 16#0060#),
                     (NIC.Transmit_Absolute_Delay_Register,
                      Named ("transmit absolute delay"), 16#0080#),
                     (NIC.Interrupt_Throttle_Register,
                      Named ("interrupt throttle"), 16#00A0#)];
                  Kept : Natural := 0;
               begin
                  for Each of Timers loop
                     Reg.Write_32 (BAR, Reg.Offset (Each.Where), Each.Value);
                     if Reg.Read_32 (BAR, Reg.Offset (Each.Where))
                       = Each.Value
                     then
                        Kept := Kept + 1;
                     else
                        Harness.Note
                          ("the " & Each.Name & " register was given 0x"
                           & Hex_32 (Each.Value) & " and reads back 0x"
                           & Hex_32 (Reg.Read_32
                                       (BAR, Reg.Offset (Each.Where))));
                     end if;
                  end loop;
                  Harness.Check
                    (Kept >= Timers'Length - 1,
                     "the interrupt moderation timers hold the values they"
                     & " are given; what they then do to the timing of an"
                     & " interrupt is not something a loopback test can"
                     & " observe, and this does not claim to");
                  if Kept < Timers'Length then
                     Harness.Skip
                       ("one moderation timer",
                        "this device takes the value and reads back zero,"
                        & " so a driver cannot read back what it set");
                  end if;
                  for Each of Timers loop
                     Reg.Write_32 (BAR, Reg.Offset (Each.Where), 0);
                  end loop;
               end;

               ------------------------------------------------------
               --  Holding the sender back
               ------------------------------------------------------

               declare
                  --  The address a pause frame carries is fixed by the
                  --  standard, and a device holding anything else here does
                  --  not recognise a pause it is sent.
                  Standard_Low  : constant U32 := 16#00C2_8001#;
                  Standard_High : constant U32 := 16#0000_0100#;
               begin
                  Reg.Write_32
                    (BAR, NIC.Flow_Control_Address_Low, Standard_Low);
                  Reg.Write_32
                    (BAR, NIC.Flow_Control_Address_High, Standard_High);
                  Reg.Write_32 (BAR, NIC.Flow_Control_Type, 16#8808#);
                  Reg.Write_32 (BAR, NIC.Flow_Control_Timer_Register, 16#0100#);
                  Reg.Write_32 (BAR, NIC.Flow_Control_High_Water, 16#4000#);
                  Reg.Write_32 (BAR, NIC.Flow_Control_Low_Water, 16#2000#);

                  Harness.Check
                    (Reg.Read_32 (BAR, NIC.Flow_Control_Address_Low)
                       = Standard_Low
                     and then Reg.Read_32
                                (BAR, NIC.Flow_Control_Address_High)
                              = Standard_High,
                     "the device holds the multicast address a pause frame"
                     & " is sent to");
                  Harness.Check
                    (Reg.Read_32 (BAR, NIC.Flow_Control_Type) = 16#8808#,
                     "and the ethertype that marks one");
                  Harness.Check
                    (Reg.Read_32 (BAR, NIC.Flow_Control_High_Water)
                       > Reg.Read_32 (BAR, NIC.Flow_Control_Low_Water),
                     "and two watermarks the right way round: a pause is"
                     & " sent when the buffer fills past the high one and"
                     & " released when it drains below the low one, and"
                     & " reversing them asks the device to pause an empty"
                     & " buffer");
               end;

               ------------------------------------------------------
               --  Agreeing a speed
               ------------------------------------------------------

               declare
                  Status : constant U16 :=
                    NIC.Read_PHY (BAR, NIC.PHY_Status);
                  Control : constant U16 :=
                    NIC.Read_PHY (BAR, NIC.PHY_Control);
                  Offered : constant U16 :=
                    NIC.Read_PHY (BAR, NIC.PHY_Advertisement);
                  Partner : constant U16 :=
                    NIC.Read_PHY (BAR, NIC.PHY_Partner_Ability);
               begin
                  Harness.Note
                    ("PHY control 0x" & Hex_16 (Control)
                     & ", status 0x" & Hex_16 (Status)
                     & ", offering 0x" & Hex_16 (Offered)
                     & ", partner 0x" & Hex_16 (Partner));
                  Harness.Check
                    ((Status and NIC.PHY_Can_Negotiate) /= 0,
                     "the physical layer says it can negotiate a speed");
                  Harness.Check
                    ((Control and NIC.PHY_Negotiation_Enabled) /= 0,
                     "and is set to negotiate rather than assume one");
                  if (Status and NIC.PHY_Negotiation_Complete) /= 0 then
                     Harness.Check
                       (Partner /= 0,
                        "negotiation has finished and the other end said"
                        & " what it can do, which is the register that"
                        & " means nothing until it has");
                  else
                     Harness.Skip
                       ("what the other end can do",
                        "negotiation has not finished on this device, so"
                        & " the partner register holds nothing yet");
                  end if;
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

   Harness.Report ("e1000e_queues_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_queues_tests");
end E1000E_Queues_Tests;
