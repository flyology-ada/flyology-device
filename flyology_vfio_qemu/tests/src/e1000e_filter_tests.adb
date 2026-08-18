--  Which frames the device keeps, and what it says about them.
--
--  A network controller spends most of its life refusing frames. On a
--  shared medium nearly everything it sees belongs to someone else, and the
--  filter is what keeps the host from being told about all of it. The
--  existing tests here send a frame to the device's own address and get it
--  back, which exercises the one case the filter always allows.
--
--  So these frames are addressed elsewhere. A test that only checks
--  arrivals cannot tell a working filter from an absent one — both deliver
--  the frame you addressed to yourself — so each check below has a matching
--  one where the frame should be dropped, and the drop is what makes the
--  arrival mean something.
--
--  The frames are real: an Ethernet header, an IPv4 header with a correct
--  checksum, a UDP header, and a payload. That matters for the last part of
--  this, where the device is asked to check those checksums and then to
--  compute one itself. A frame of arbitrary bytes would be refused by the
--  checksum logic for reasons that had nothing to do with the addresses.

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
with System.Storage_Elements;

procedure E1000E_Filter_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package NIC renames Flyology_VFIO_QEMU.E1000E;
   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type SSE.Storage_Offset;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   Ring_Slots   : constant := 16;
   Buffer_Bytes : constant := 4096;

   RX_Ring_Offset : constant DMA.Byte_Count := 0;
   TX_Ring_Offset : constant DMA.Byte_Count := 4096;
   Frame_Offset   : constant DMA.Byte_Count := 8192;
   Buffers_Offset : constant DMA.Byte_Count := 16384;
   Scratch_Bytes  : constant :=
     16384 + Buffer_Bytes * Ring_Slots;

   --  Somewhere to send frames that is not this device and not a
   --  broadcast, so an exact-match filter has to refuse it.
   Stranger : constant NIC.MAC_Address :=
     [16#02#, 16#DE#, 16#AD#, 16#BE#, 16#EF#, 16#01#];

   --  Locally administered multicast, which is what the low bit of the
   --  first byte means and the whole reason the hash table exists.
   Group_One : constant NIC.MAC_Address :=
     [16#01#, 16#00#, 16#5E#, 16#00#, 16#00#, 16#16#];
   Group_Two : constant NIC.MAC_Address :=
     [16#01#, 16#00#, 16#5E#, 16#7F#, 16#12#, 16#34#];

   Broadcast : constant NIC.MAC_Address := [others => 16#FF#];

   Tagged_VLAN : constant NIC.VLAN_Identifier := 42;
   Other_VLAN  : constant NIC.VLAN_Identifier := 43;
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
               pragma Unreferenced (Bound);

               Host : constant System.Address :=
                 DMA.Regions.Base_Address (Area);

               function At_Host (Offset : DMA.Byte_Count)
                 return System.Address
               is (Host + SSE.Storage_Offset (Offset));

               function At_Device (Offset : DMA.Byte_Count) return U64
               is (U64 (Window_Base) + U64 (Offset));

               RX : constant NIC.Ring_Location :=
                 (Host   => At_Host (RX_Ring_Offset),
                  Device => At_Device (RX_Ring_Offset),
                  Count  => Ring_Slots,
                  Queue  => 0);
               TX : constant NIC.Ring_Location :=
                 (Host   => At_Host (TX_Ring_Offset),
                  Device => At_Device (TX_Ring_Offset),
                  Count  => Ring_Slots,
                  Queue  => 0);

               Everything : array (1 .. Scratch_Bytes) of U8
                 with Import, Volatile, Address => Host;
               Frame : array (0 .. 2047) of U8
                 with Import, Volatile, Address => At_Host (Frame_Offset);

               Mine : NIC.MAC_Address;

               RX_Slot : Natural := 0;
               TX_Slot : Natural := 0;

               --  Where the interesting parts of a frame sit once it is
               --  built. Untagged: the IP header follows fourteen bytes of
               --  Ethernet header. Tagged: four more.
               Ethernet_Bytes : constant := 14;
               IP_Bytes       : constant := 20;
               UDP_Bytes      : constant := 8;
               Payload_Bytes  : constant := 32;

               procedure Put_16_At (Where : Natural; Value : U16);
               function Ones_Complement
                 (From : Natural; Length : Natural) return U16;
               function Build
                 (Destination : NIC.MAC_Address;
                  VLAN        : Integer := -1;
                  Payload     : Natural := Payload_Bytes;
                  Spoil_IP    : Boolean := False;
                  Blank_UDP   : Boolean := False) return Positive;
               function Try
                 (Length : Positive;
                  Options : NIC.Transmit_Options := (others => <>))
                  return NIC.Received_Frame;

               procedure Put_16_At (Where : Natural; Value : U16) is
               begin
                  --  Network order, which is the opposite of everything
                  --  else in this repository and the reason these two lines
                  --  exist rather than an overlay.
                  Frame (Where) := U8 (Interfaces.Shift_Right (Value, 8));
                  Frame (Where + 1) := U8 (Value and 16#FF#);
               end Put_16_At;

               function Ones_Complement
                 (From : Natural; Length : Natural) return U16
               is
                  Sum : U32 := 0;
                  At_Byte : Natural := From;
               begin
                  while At_Byte < From + Length loop
                     Sum := Sum
                       + Interfaces.Shift_Left (U32 (Frame (At_Byte)), 8)
                       + U32 (Frame (At_Byte + 1));
                     At_Byte := At_Byte + 2;
                  end loop;
                  while Interfaces.Shift_Right (Sum, 16) /= 0 loop
                     Sum := (Sum and 16#FFFF#)
                            + Interfaces.Shift_Right (Sum, 16);
                  end loop;
                  return not U16 (Sum and 16#FFFF#);
               end Ones_Complement;

               function Build
                 (Destination : NIC.MAC_Address;
                  VLAN        : Integer := -1;
                  Payload     : Natural := Payload_Bytes;
                  Spoil_IP    : Boolean := False;
                  Blank_UDP   : Boolean := False) return Positive
               is
                  Tag_Bytes : constant Natural := (if VLAN < 0 then 0 else 4);
                  IP_At     : constant Natural := Ethernet_Bytes + Tag_Bytes;
                  UDP_At    : constant Natural := IP_At + IP_Bytes;
                  Data_At   : constant Natural := UDP_At + UDP_Bytes;
                  Total     : constant Positive := Data_At + Payload;
               begin
                  for Index in 0 .. Total - 1 loop
                     Frame (Index) := 0;
                  end loop;

                  for Index in 1 .. 6 loop
                     Frame (Index - 1) := Destination (Index);
                     Frame (5 + Index) := Mine (Index);
                  end loop;

                  if VLAN >= 0 then
                     Put_16_At (12, 16#8100#);
                     Put_16_At (14, U16 (VLAN));
                  end if;
                  Put_16_At (Ethernet_Bytes + Tag_Bytes - 2, 16#0800#);

                  --  A twenty-byte IPv4 header carrying UDP.
                  Frame (IP_At) := 16#45#;
                  Put_16_At (IP_At + 2, U16 (IP_Bytes + UDP_Bytes + Payload));
                  Put_16_At (IP_At + 4, 16#1234#);
                  Frame (IP_At + 8) := 64;
                  Frame (IP_At + 9) := 17;
                  Frame (IP_At + 12) := 10;
                  Frame (IP_At + 15) := 1;
                  Frame (IP_At + 16) := 10;
                  Frame (IP_At + 19) := 2;
                  Put_16_At (IP_At + 10, Ones_Complement (IP_At, IP_Bytes));

                  if Spoil_IP then
                     --  One bit, so the header is still a header and only
                     --  the checksum is wrong.
                     Frame (IP_At + 11) := Frame (IP_At + 11) xor 1;
                  end if;

                  Put_16_At (UDP_At, 4_096);
                  Put_16_At (UDP_At + 2, 4_097);
                  Put_16_At (UDP_At + 4, U16 (UDP_Bytes + Payload));

                  for Index in 0 .. Payload - 1 loop
                     Frame (Data_At + Index) := U8 ((Index * 7 + 3) mod 251);
                  end loop;

                  if not Blank_UDP then
                     --  A UDP checksum of zero means "not computed", which
                     --  every receiver accepts. Leaving it there is what
                     --  makes the device's own computation visible when it
                     --  is asked for one.
                     declare
                        Pseudo : U32 := 0;
                     begin
                        Pseudo := Pseudo
                          + 16#0A00# + 16#0001# + 16#0A00# + 16#0002#
                          + 17 + U32 (UDP_Bytes + Payload);
                        Sum_Loop :
                        declare
                           Body_Sum : constant U16 :=
                             Ones_Complement (UDP_At, UDP_Bytes + Payload);
                           Whole : U32 :=
                             U32 (not Body_Sum) + Pseudo;
                        begin
                           while Interfaces.Shift_Right (Whole, 16) /= 0 loop
                              Whole := (Whole and 16#FFFF#)
                                       + Interfaces.Shift_Right (Whole, 16);
                           end loop;
                           Put_16_At
                             (UDP_At + 6, not U16 (Whole and 16#FFFF#));
                        end Sum_Loop;
                     end;
                  end if;

                  return Total;
               end Build;

               --  Sends what is in the frame buffer and reports what came
               --  back, if anything. A frame the filter refuses simply
               --  never arrives, so the absence has to be waited for rather
               --  than detected.
               function Try
                 (Length : Positive;
                  Options : NIC.Transmit_Options := (others => <>))
                  return NIC.Received_Frame
               is
                  Seen : NIC.Received_Frame;
               begin
                  NIC.Transmit
                    (BAR, TX, TX_Slot, At_Device (Frame_Offset), Length,
                     Options);
                  TX_Slot := (TX_Slot + 1) mod Ring_Slots;

                  for Attempt in 1 .. 200 loop
                     Seen := NIC.Peek_Received (RX, RX_Slot);
                     exit when Seen.Arrived;
                     delay 0.001;
                  end loop;

                  if Seen.Arrived then
                     NIC.Recycle_Received
                       (BAR, RX, RX_Slot,
                        At_Device (Buffers_Offset
                                   + DMA.Byte_Count (RX_Slot * Buffer_Bytes)));
                     RX_Slot := (RX_Slot + 1) mod Ring_Slots;
                  end if;
                  return Seen;
               end Try;
            begin
               Everything := (others => 0);
               NIC.Reset (BAR);

               Mine := NIC.Hardware_Address (BAR);
               Harness.Note ("its address is " & NIC.Image (Mine));
               Harness.Check
                 (NIC.Hardware_Address_Valid (BAR),
                  "the device holds a valid address of its own, which is"
                  & " what an exact-match filter matches against");

               NIC.Start_Receiving
                 (BAR, RX, At_Device (Buffers_Offset), Buffer_Bytes);
               NIC.Start_Transmitting (BAR, TX);

               --  The whole filter, stated in one write: keep frames,
               --  loop them back, strip the frame check, take four
               --  kibibyte buffers, and check the checksums of what
               --  arrives. Every later change is a bit added to or taken
               --  from this.
               declare
                  Filter : constant U32 :=
                    NIC.Receive_Enable or NIC.Receive_Broadcast
                    or NIC.Receive_Strip_CRC or NIC.Receive_Loopback
                    or NIC.Receive_Buffer_Size_Bits (Buffer_Bytes);
               begin
                  Reg.Write_32 (BAR, NIC.Receive_Control_Register, Filter);
                  Reg.Write_32
                    (BAR, NIC.Receive_Checksum_Register,
                     NIC.Checksum_Offload_IP
                     or NIC.Checksum_Offload_Transport);
                  NIC.Clear_Multicast_Table (BAR);
                  NIC.Clear_VLAN_Filters (BAR);

                  ------------------------------------------------------
                  --  Unicast
                  ------------------------------------------------------

                  declare
                     Length : constant Positive := Build (Mine);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (Seen.Arrived,
                        "a frame addressed to the device arrives, which is"
                        & " the case every filter allows and the only one"
                        & " the other tests here reach");
                     Harness.Note
                       ("an exact match has status byte 0x"
                        & Hex_16 (U16 (Seen.Status)));
                  end;

                  declare
                     Length : constant Positive := Build (Stranger);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (not Seen.Arrived,
                        "a frame addressed to somebody else does not, so"
                        & " the filter is refusing rather than absent");
                  end;

                  Reg.Write_32
                    (BAR, NIC.Receive_Control_Register,
                     Filter or NIC.Receive_Unicast_Promiscuous);
                  declare
                     Length : constant Positive := Build (Stranger);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (Seen.Arrived,
                        "and arrives once the device is told to keep"
                        & " everything, so the refusal was the filter's"
                        & " decision and not the loopback path losing it");
                  end;
                  Reg.Write_32 (BAR, NIC.Receive_Control_Register, Filter);

                  ------------------------------------------------------
                  --  Broadcast and multicast
                  ------------------------------------------------------

                  declare
                     Length : constant Positive := Build (Broadcast);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (Seen.Arrived,
                        "a broadcast arrives, which is a separate bit from"
                        & " every other kind of acceptance");
                  end;

                  declare
                     Length : constant Positive := Build (Group_One);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (not Seen.Arrived,
                        "a multicast frame is refused while the hash table"
                        & " is empty");
                  end;

                  Harness.Note
                    ("that group hashes to bit"
                     & Natural'Image (NIC.Multicast_Bit (Group_One))
                     & " and the other to"
                     & Natural'Image (NIC.Multicast_Bit (Group_Two)));

                  NIC.Set_Multicast (BAR, Group_One, True);
                  declare
                     Length : constant Positive := Build (Group_One);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (Seen.Arrived,
                        "and arrives once its hash bit is set, so the"
                        & " hash this code computes is the hash the device"
                        & " computes — which is the part of a multicast"
                        & " filter that is easy to get wrong and silent"
                        & " when wrong");
                     if (Seen.Status and NIC.Descriptor_Inexact_Filter) /= 0
                     then
                        Harness.Check
                          (True,
                           "the descriptor says it passed an inexact"
                           & " filter, so a driver knows to check the"
                           & " address itself rather than trusting a hash"
                           & " that collides");
                     else
                        Harness.Skip
                          ("the inexact-filter bit",
                           "this device gives a hash match the same status"
                           & " byte as an exact match, 0x"
                           & Hex_16 (U16 (Seen.Status))
                           & ", so a driver cannot tell from the descriptor"
                           & " that it must check the address itself");
                     end if;
                  end;

                  declare
                     Length : constant Positive := Build (Group_Two);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (not Seen.Arrived,
                        "a different multicast group is still refused, so"
                        & " setting one bit did not open the table");
                  end;

                  Reg.Write_32
                    (BAR, NIC.Receive_Control_Register,
                     Filter or NIC.Receive_Multicast_Promiscuous);
                  declare
                     Length : constant Positive := Build (Group_Two);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (Seen.Arrived,
                        "until the device is told to keep every multicast");
                  end;
                  Reg.Write_32 (BAR, NIC.Receive_Control_Register, Filter);
                  NIC.Clear_Multicast_Table (BAR);

                  ------------------------------------------------------
                  --  VLAN
                  ------------------------------------------------------

                  Reg.Write_32 (BAR, NIC.VLAN_Ether_Type_Register, 16#8100#);
                  Reg.Write_32
                    (BAR, NIC.Control_Register,
                     Reg.Read_32 (BAR, NIC.Control_Register)
                     or NIC.Control_VLAN_Mode);
                  Reg.Write_32
                    (BAR, NIC.Receive_Control_Register,
                     Filter or NIC.Receive_VLAN_Filter);

                  declare
                     Length : constant Positive :=
                       Build (Mine, VLAN => Integer (Tagged_VLAN));
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (not Seen.Arrived,
                        "a tagged frame is refused while no VLAN is"
                        & " allowed, even though its address matches");
                  end;

                  NIC.Set_VLAN_Filter (BAR, Tagged_VLAN, True);
                  Harness.Check
                    (NIC.VLAN_Filter_Allows (BAR, Tagged_VLAN)
                     and then not NIC.VLAN_Filter_Allows (BAR, Other_VLAN),
                     "the filter table reads back holding one VLAN and not"
                     & " its neighbour, so the bit arithmetic addresses one"
                     & " identifier rather than a range of them");

                  declare
                     Length : constant Positive :=
                       Build (Mine, VLAN => Integer (Tagged_VLAN));
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (Seen.Arrived,
                        "and the frame arrives once its VLAN is allowed");
                     if Seen.Arrived then
                        Harness.Check
                          ((Seen.Status and NIC.Descriptor_VLAN_Present) /= 0,
                           "the descriptor says the frame was tagged");
                        Harness.Check_Equal
                          (U32 (Seen.VLAN_Tag and 16#FFF#),
                           U32 (Tagged_VLAN),
                           "and carries the identifier");
                        Harness.Check_Equal
                          (U32 (Seen.Length), U32 (Length - 4),
                           "and the frame is four bytes shorter than it was"
                           & " sent, because the tag is in the descriptor"
                           & " now and not in the bytes");
                     end if;
                  end;

                  declare
                     Length : constant Positive :=
                       Build (Mine, VLAN => Integer (Other_VLAN));
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     Harness.Check
                       (not Seen.Arrived,
                        "a frame on the neighbouring VLAN is still"
                        & " refused");
                  end;

                  Reg.Write_32 (BAR, NIC.Receive_Control_Register, Filter);
                  NIC.Clear_VLAN_Filters (BAR);

                  ------------------------------------------------------
                  --  Checking checksums, and computing one
                  ------------------------------------------------------

                  declare
                     Length : constant Positive := Build (Mine);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     if not Seen.Arrived then
                        Harness.Skip
                          ("every checksum check", "the frame did not"
                           & " arrive at all");
                     else
                        Harness.Check
                          ((Seen.Status and NIC.Descriptor_IP_Checked) /= 0,
                           "the device says it checked the IP header"
                           & " checksum, which is what makes the verdict"
                           & " below a verdict rather than a stale byte");
                        Harness.Check
                          ((Seen.Errors and NIC.Descriptor_IP_Checksum_Error)
                             = 0,
                           "and found it sound, so the checksum this test"
                           & " computed is the one the device computes");
                        Harness.Check
                          ((Seen.Errors
                            and NIC.Descriptor_Transport_Checksum_Error) = 0,
                           "and found the UDP checksum sound too");
                     end if;
                  end;

                  declare
                     Length : constant Positive :=
                       Build (Mine, Spoil_IP => True);
                     Seen : constant NIC.Received_Frame := Try (Length);
                  begin
                     if Seen.Arrived then
                        Harness.Check
                          ((Seen.Errors and NIC.Descriptor_IP_Checksum_Error)
                             /= 0,
                           "one bit flipped in the IP checksum and the"
                           & " device notices, so it is computing the"
                           & " checksum rather than reporting that it did");
                     else
                        Harness.Skip
                          ("noticing a wrong checksum",
                           "the device dropped the frame instead of"
                           & " delivering it with the error marked");
                     end if;
                  end;

                  declare
                     --  Sent with the UDP checksum left at zero and the
                     --  device asked to fill it in. If it does, the frame
                     --  comes back with a sound checksum; if it ignores the
                     --  request, the zero arrives and means "not computed",
                     --  which is also not an error — so the check is on the
                     --  bytes rather than on the verdict.
                     Length : constant Positive :=
                       Build (Mine, Blank_UDP => True);
                     UDP_At : constant Natural := Ethernet_Bytes + IP_Bytes;
                     Options : constant NIC.Transmit_Options :=
                       (Insert_Checksum => True,
                        Checksum_Start  => UDP_At,
                        Checksum_Offset => UDP_At + 6,
                        others          => <>);
                     Seen : constant NIC.Received_Frame :=
                       Try (Length, Options);
                     Landed : array (0 .. Buffer_Bytes - 1) of U8
                       with Import, Volatile,
                       Address => At_Host (Buffers_Offset);
                     Filled : U16 := 0;
                  begin
                     if not Seen.Arrived then
                        Harness.Skip
                          ("inserting a checksum",
                           "the frame did not come back");
                     else
                        Filled :=
                          Interfaces.Shift_Left
                            (U16 (Landed (UDP_At + 6)), 8)
                          or U16 (Landed (UDP_At + 7));
                        Harness.Note
                          ("the device wrote 0x" & Hex_16 (Filled)
                           & " where the UDP checksum goes");
                        if Filled = 0 then
                           Harness.Skip
                             ("inserting a checksum",
                              "this device left the field alone, so it"
                              & " does not implement checksum insertion"
                              & " through the legacy descriptor");
                        else
                           Harness.Check
                             ((Seen.Errors
                               and NIC.Descriptor_Transport_Checksum_Error)
                                = 0,
                              "the device computed a UDP checksum on the way"
                              & " out and accepted it on the way back in,"
                              & " which is the same device agreeing with"
                              & " itself across the loopback");
                        end if;
                     end if;
                  end;

                  ------------------------------------------------------
                  --  Frames larger than the standard maximum
                  ------------------------------------------------------

                  declare
                     Long : constant := 2_000;
                     Length : constant Positive :=
                       Build (Mine, Payload => Long);
                     Seen : NIC.Received_Frame;
                  begin
                     Seen := Try (Length);
                     Harness.Check
                       (not Seen.Arrived,
                        "a frame past the standard maximum is refused while"
                        & " long packets are switched off");

                     Reg.Write_32
                       (BAR, NIC.Receive_Packet_Length_Register, 4_088);
                     Reg.Write_32
                       (BAR, NIC.Receive_Control_Register,
                        Filter or NIC.Receive_Long_Packets);
                     declare
                        Again : constant Positive :=
                          Build (Mine, Payload => Long);
                        Big : constant NIC.Received_Frame := Try (Again);
                     begin
                        Harness.Check
                          (Big.Arrived,
                           "and arrives once they are allowed and the"
                           & " maximum is raised, both of which are needed:"
                           & " the bit alone leaves the old limit in place");
                        if Big.Arrived then
                           Harness.Check_Equal
                             (U32 (Big.Length), U32 (Again),
                              "whole, in one descriptor");
                        end if;
                     end;
                     Reg.Write_32
                       (BAR, NIC.Receive_Control_Register, Filter);
                  end;
               end;
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   Harness.Report ("e1000e_filter_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_filter_tests");
end E1000E_Filter_Tests;
