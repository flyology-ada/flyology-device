--  Talking to something that talks back.
--
--  Every frame test before this one loops back: the device is told to send
--  a frame to itself, and it arrives. That proves the rings work and the
--  addresses are right, and it cannot prove the frame was correct. Both
--  directions run through the same emulated code, so a field that code does
--  not look at can hold anything at all and the frame still comes back
--  looking perfect.
--
--  On the other side of the virtual hub is the guest's own kernel. It
--  answers address resolution, replies to echo requests, reports
--  unreachable ports, and refuses connections to closed ones with a reset
--  — and it does none of those things for a frame whose checksum is wrong.
--  A stack drops a bad segment silently rather than complaining about it,
--  so silence is the failure mode and a reply is the proof.
--
--  That makes each check here narrow and worth having. The address
--  resolution reply proves the Ethernet header. The echo reply proves the
--  IPv4 header and its checksum. The unreachable report proves the UDP
--  checksum, computed over a header the datagram does not contain. The
--  reset proves the same for TCP, where the checksum is not optional and a
--  wrong one is indistinguishable from a frame that never arrived.
--
--  It is also the only place receive-side scaling can be observed, because
--  this device hashes frames arriving from outside and not frames it sent
--  itself.

with Ada.Environment_Variables;
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

procedure E1000E_Peer_Tests is
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
   use type NIC.MAC_Address;
   use type NIC.Queue_Index;
   use type System.Address;
   use type SSE.Storage_Offset;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   Ring_Slots   : constant := 32;
   Buffer_Bytes : constant := 2048;

   RX0_Ring    : constant DMA.Byte_Count := 0;
   RX1_Ring    : constant DMA.Byte_Count := 4096;
   TX_Ring     : constant DMA.Byte_Count := 8192;
   Frame_At    : constant DMA.Byte_Count := 12288;
   RX0_Buffers : constant DMA.Byte_Count := 16384;
   Scratch_Bytes : constant :=
     16384 + 2 * Buffer_Bytes * Ring_Slots;

   --  An address on the peer's network that nothing else is using. The
   --  device has no address of its own — it is not the kernel's — so this
   --  picks one, and the peer learns it from the first frame sent, because
   --  a stack records where an address resolution request came from.
   Our_IP : constant U32 := 16#0A00_0263#;   --  10.0.2.99

   --  A port with nothing listening on it. That is what makes the replies
   --  deterministic: what an open port does depends on what is listening
   --  and what a closed one does does not.
   Closed_Port : constant U16 := 9_999;

   function Setting (Name, Otherwise : String) return String
   is (if Ada.Environment_Variables.Exists (Name)
       then Ada.Environment_Variables.Value (Name) else Otherwise);

   function Dotted (Text : String) return U32 is
      Result : U32 := 0;
      Part   : U32 := 0;
   begin
      for Digit of Text loop
         if Digit = '.' then
            Result := Interfaces.Shift_Left (Result, 8) or Part;
            Part := 0;
         else
            Part := Part * 10
              + U32 (Character'Pos (Digit) - Character'Pos ('0'));
         end if;
      end loop;
      return Interfaces.Shift_Left (Result, 8) or Part;
   end Dotted;

   Peer_IP  : constant U32 :=
     Dotted (Setting ("FLYOLOGY_DEVICE_VM_PEER_IP", "10.0.2.50"));
   Peer_MAC : constant NIC.MAC_Address :=
     NIC.Value (Setting ("FLYOLOGY_DEVICE_VM_PEER_MAC", "52:54:00:12:34:57"));

   --  What a reply has to look like for this test to be interested. The hub
   --  carries the peer, this device, and QEMU's own translating stack, so
   --  frames arrive that have nothing to do with the check in progress and
   --  have to be walked past rather than mistaken for a failure.
   type Expected is
     (Address_Reply, Echo_Reply, Port_Unreachable, Connection_Refused);
begin
   declare
      Where : constant String := Find (NIC.Vendor_ID, NIC.Device_ID);
      Container : Container_FD;
      Group     : Group_FD;
      Device    : Device_FD;
   begin
      Harness.Note ("device at " & Where);
      Harness.Note
        ("its peer is " & NIC.Image (Peer_MAC) & " at "
         & Setting ("FLYOLOGY_DEVICE_VM_PEER_IP", "10.0.2.50"));

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

               RX : constant array (NIC.Queue_Index) of NIC.Ring_Location :=
                 [0 => (Host   => At_Host (RX0_Ring),
                        Device => At_Device (RX0_Ring),
                        Count  => Ring_Slots, Queue => 0),
                  1 => (Host   => At_Host (RX1_Ring),
                        Device => At_Device (RX1_Ring),
                        Count  => Ring_Slots, Queue => 1)];
               TX : constant NIC.Ring_Location :=
                 (Host   => At_Host (TX_Ring),
                  Device => At_Device (TX_Ring),
                  Count  => Ring_Slots, Queue => 0);

               Everything : array (1 .. Scratch_Bytes) of U8
                 with Import, Volatile, Address => Host;
               Frame : array (0 .. 1023) of U8
                 with Import, Volatile, Address => At_Host (Frame_At);

               --  Both queues' buffers, addressed as one block because the
               --  second follows the first. Reading an arriving frame is
               --  the point of this test, so the buffers are named rather
               --  than only handed to the device.
               Arrived : array (NIC.Queue_Index, 0 .. Ring_Slots - 1,
                                0 .. Buffer_Bytes - 1) of U8
                 with Import, Volatile, Address => At_Host (RX0_Buffers);

               function Buffer_Device
                 (Queue : NIC.Queue_Index; Slot : Natural) return U64
               is (At_Device
                     (RX0_Buffers
                      + DMA.Byte_Count (NIC.Queue_Index'Pos (Queue))
                        * Buffer_Bytes * Ring_Slots
                      + DMA.Byte_Count (Slot * Buffer_Bytes)));

               Mine : NIC.MAC_Address;
               Extended : Boolean := False;
               RX_Slot : array (NIC.Queue_Index) of Natural := [0, 0];
               TX_Slot : Natural := 0;

               IP_At    : constant := 14;
               Trans_At : constant := 34;

               procedure Put_16_At (Where : Natural; Value : U16);
               procedure Put_32_At (Where : Natural; Value : U32);
               function Word_Sum (From, Length : Natural) return U32;
               function Folded (Sum : U32) return U16;
               function Pseudo_Header (Protocol, Length : U32) return U32;
               procedure Start_Frame (Kind : U16);
               function Finish_IPv4
                 (Protocol : U8; Payload : Natural) return Positive;
               function Build_ARP return Positive;
               function Build_Echo return Positive;
               function Build_UDP return Positive;
               function Build_SYN return Positive;
               procedure Send (Length : Positive);
               function Matches
                 (Wanted : Expected;
                  Queue  : NIC.Queue_Index;
                  Slot   : Natural) return Boolean;
               procedure Exchange
                 (Length : Positive;
                  Wanted : Expected;
                  Found  : out Boolean;
                  Queue  : out NIC.Queue_Index;
                  Slot   : out Natural);

               procedure Put_16_At (Where : Natural; Value : U16) is
               begin
                  --  Network order, which is the opposite of everything
                  --  else here and the reason this is two lines rather
                  --  than an overlay.
                  Frame (Where) := U8 (Interfaces.Shift_Right (Value, 8));
                  Frame (Where + 1) := U8 (Value and 16#FF#);
               end Put_16_At;

               procedure Put_32_At (Where : Natural; Value : U32) is
               begin
                  Put_16_At (Where, U16 (Interfaces.Shift_Right (Value, 16)));
                  Put_16_At (Where + 2, U16 (Value and 16#FFFF#));
               end Put_32_At;

               --  Uncomplemented and unfolded, so a caller can add the
               --  words of a header the datagram does not carry before
               --  finishing it off. That is the whole difficulty of a
               --  transport checksum and where a driver gets it wrong.
               function Word_Sum (From, Length : Natural) return U32 is
                  Sum : U32 := 0;
                  At_Byte : Natural := From;
               begin
                  while At_Byte + 1 < From + Length loop
                     Sum := Sum
                       + Interfaces.Shift_Left (U32 (Frame (At_Byte)), 8)
                       + U32 (Frame (At_Byte + 1));
                     At_Byte := At_Byte + 2;
                  end loop;
                  if At_Byte < From + Length then
                     Sum := Sum
                       + Interfaces.Shift_Left (U32 (Frame (At_Byte)), 8);
                  end if;
                  return Sum;
               end Word_Sum;

               function Folded (Sum : U32) return U16 is
                  Carried : U32 := Sum;
               begin
                  while Interfaces.Shift_Right (Carried, 16) /= 0 loop
                     Carried := (Carried and 16#FFFF#)
                                + Interfaces.Shift_Right (Carried, 16);
                  end loop;
                  return not U16 (Carried and 16#FFFF#);
               end Folded;

               --  The addresses, the protocol and the length, summed as
               --  though they were part of the datagram. They are not sent
               --  and both ends have to invent them identically.
               function Pseudo_Header (Protocol, Length : U32) return U32
               is (Interfaces.Shift_Right (Our_IP, 16)
                   + (Our_IP and 16#FFFF#)
                   + Interfaces.Shift_Right (Peer_IP, 16)
                   + (Peer_IP and 16#FFFF#)
                   + Protocol + Length);

               procedure Start_Frame (Kind : U16) is
               begin
                  for Index in Frame'Range loop
                     Frame (Index) := 0;
                  end loop;
                  for Index in 1 .. 6 loop
                     --  Broadcast only for address resolution. Sending
                     --  everything to the broadcast address would work and
                     --  would stop this proving the peer learned anything.
                     Frame (Index - 1) :=
                       (if Kind = 16#0806# then 16#FF# else Peer_MAC (Index));
                     Frame (5 + Index) := Mine (Index);
                  end loop;
                  Put_16_At (12, Kind);
               end Start_Frame;

               function Finish_IPv4
                 (Protocol : U8; Payload : Natural) return Positive is
               begin
                  Frame (IP_At) := 16#45#;
                  Put_16_At (IP_At + 2, U16 (20 + Payload));
                  Put_16_At (IP_At + 4, 16#ABCD#);
                  Frame (IP_At + 8) := 64;
                  Frame (IP_At + 9) := Protocol;
                  Put_32_At (IP_At + 12, Our_IP);
                  Put_32_At (IP_At + 16, Peer_IP);
                  Put_16_At (IP_At + 10, Folded (Word_Sum (IP_At, 20)));
                  return IP_At + 20 + Payload;
               end Finish_IPv4;

               function Build_ARP return Positive is
               begin
                  Start_Frame (16#0806#);
                  Put_16_At (14, 1);         --  over Ethernet
                  Put_16_At (16, 16#0800#);  --  resolving IPv4
                  Frame (18) := 6;
                  Frame (19) := 4;
                  Put_16_At (20, 1);         --  a request
                  for Index in 1 .. 6 loop
                     Frame (21 + Index) := Mine (Index);
                  end loop;
                  Put_32_At (28, Our_IP);
                  --  The target hardware address is left empty: it is what
                  --  is being asked for.
                  Put_32_At (38, Peer_IP);
                  return 42;
               end Build_ARP;

               function Build_Echo return Positive is
                  Payload : constant := 32;
               begin
                  Start_Frame (16#0800#);
                  Frame (Trans_At) := 8;     --  echo request
                  Put_16_At (Trans_At + 4, 16#1234#);
                  Put_16_At (Trans_At + 6, 1);
                  for Index in 0 .. Payload - 1 loop
                     Frame (Trans_At + 8 + Index) :=
                       U8 ((Index * 11 + 5) mod 251);
                  end loop;
                  --  No pseudo-header here, which is what makes this a
                  --  useful step between the IP checksum and the two below.
                  Put_16_At
                    (Trans_At + 2,
                     Folded (Word_Sum (Trans_At, 8 + Payload)));
                  return Finish_IPv4 (1, 8 + Payload);
               end Build_Echo;

               function Build_UDP return Positive is
                  Payload : constant := 16;
                  Length  : constant := 8 + Payload;
               begin
                  Start_Frame (16#0800#);
                  Put_16_At (Trans_At, 5_000);
                  Put_16_At (Trans_At + 2, Closed_Port);
                  Put_16_At (Trans_At + 4, Length);
                  for Index in 0 .. Payload - 1 loop
                     Frame (Trans_At + 8 + Index) := U8 (Index + 1);
                  end loop;
                  Put_16_At
                    (Trans_At + 6,
                     Folded (Word_Sum (Trans_At, Length)
                             + Pseudo_Header (17, Length)));
                  return Finish_IPv4 (17, Length);
               end Build_UDP;

               function Build_SYN return Positive is
                  Length : constant := 20;
               begin
                  Start_Frame (16#0800#);
                  Put_16_At (Trans_At, 5_001);
                  Put_16_At (Trans_At + 2, Closed_Port);
                  Put_32_At (Trans_At + 4, 16#0001_0000#);
                  --  Five words of header in the high nibble, and the
                  --  synchronise flag. A header length of zero here is a
                  --  segment every stack discards.
                  Put_16_At (Trans_At + 12, 16#5002#);
                  Put_16_At (Trans_At + 14, 8_192);
                  Put_16_At
                    (Trans_At + 16,
                     Folded (Word_Sum (Trans_At, Length)
                             + Pseudo_Header (6, Length)));
                  return Finish_IPv4 (6, Length);
               end Build_SYN;

               procedure Send (Length : Positive) is
                  --  Short frames are padded by the device, but padding it
                  --  here keeps what is sent equal to what was built.
                  Sent : constant Positive := Positive'Max (Length, 60);
               begin
                  NIC.Transmit
                    (BAR, TX, TX_Slot, At_Device (Frame_At), Sent);
                  TX_Slot := (TX_Slot + 1) mod Ring_Slots;
               end Send;

               function Matches
                 (Wanted : Expected;
                  Queue  : NIC.Queue_Index;
                  Slot   : Natural) return Boolean
               is
                  function Byte (Where : Natural) return U8
                  is (Arrived (Queue, Slot, Where));

                  function Word (Where : Natural) return U16
                  is (Interfaces.Shift_Left (U16 (Byte (Where)), 8)
                      or U16 (Byte (Where + 1)));

                  function Long (Where : Natural) return U32
                  is (Interfaces.Shift_Left (U32 (Word (Where)), 16)
                      or U32 (Word (Where + 2)));
               begin
                  case Wanted is
                     when Address_Reply =>
                        return Word (12) = 16#0806#
                          and then Word (20) = 2
                          and then Long (28) = Peer_IP;
                     when Echo_Reply =>
                        return Word (12) = 16#0800#
                          and then Byte (IP_At + 9) = 1
                          and then Long (IP_At + 12) = Peer_IP
                          and then Byte (Trans_At) = 0;
                     when Port_Unreachable =>
                        return Word (12) = 16#0800#
                          and then Byte (IP_At + 9) = 1
                          and then Byte (Trans_At) = 3
                          and then Byte (Trans_At + 1) = 3;
                     when Connection_Refused =>
                        return Word (12) = 16#0800#
                          and then Byte (IP_At + 9) = 6
                          and then (Byte (Trans_At + 13) and 16#04#) /= 0;
                  end case;
               end Matches;

               --  Sends, then walks the rings until the wanted reply turns
               --  up or the patience runs out. Everything walked past is
               --  handed back to the device: the hub is busy and a test
               --  that stopped at the first arrival would be reading
               --  somebody else's frame.
               procedure Exchange
                 (Length : Positive;
                  Wanted : Expected;
                  Found  : out Boolean;
                  Queue  : out NIC.Queue_Index;
                  Slot   : out Natural)
               is
                  Seen : NIC.Received_Frame;
               begin
                  Found := False;
                  Queue := 0;
                  Slot  := 0;
                  Send (Length);

                  for Attempt in 1 .. 400 loop
                     for Each in NIC.Queue_Index loop
                        loop
                           Seen := NIC.Peek_Received
                             (RX (Each), RX_Slot (Each),
                              (if Extended then NIC.Extended
                               else NIC.Legacy));
                           exit when not Seen.Arrived;
                           if Matches (Wanted, Each, RX_Slot (Each)) then
                              Found := True;
                              Queue := Each;
                              Slot  := RX_Slot (Each);
                              NIC.Recycle_Received
                                (BAR, RX (Each), RX_Slot (Each),
                                 Buffer_Device (Each, RX_Slot (Each)));
                              RX_Slot (Each) :=
                                (RX_Slot (Each) + 1) mod Ring_Slots;
                              return;
                           end if;
                           NIC.Recycle_Received
                             (BAR, RX (Each), RX_Slot (Each),
                              Buffer_Device (Each, RX_Slot (Each)));
                           RX_Slot (Each) :=
                             (RX_Slot (Each) + 1) mod Ring_Slots;
                        end loop;
                     end loop;
                     delay 0.005;
                  end loop;
               end Exchange;

               Found : Boolean;
               Queue : NIC.Queue_Index;
               Slot  : Natural;
            begin
               Everything := (others => 0);
               NIC.Reset (BAR);
               Mine := NIC.Hardware_Address (BAR);
               Harness.Note ("its address is " & NIC.Image (Mine));

               Harness.Check
                 (NIC.Wait_For_Link (BAR),
                  "the device reports a link, which every loopback test"
                  & " here got away without: a looped frame never reaches"
                  & " the wire, so a device with no link passes all of them"
                  & " and sends nothing");

               for Each in NIC.Queue_Index loop
                  NIC.Start_Receiving
                    (BAR, RX (Each), Buffer_Device (Each, 0), Buffer_Bytes);
               end loop;
               NIC.Start_Transmitting (BAR, TX);

               --  No loopback this time. Every frame below leaves the
               --  device and every reply comes back off the wire.
               Reg.Write_32
                 (BAR, NIC.Receive_Control_Register,
                  NIC.Receive_Enable or NIC.Receive_Broadcast
                  or NIC.Receive_Strip_CRC);

               ------------------------------------------------------
               --  Who is out there
               ------------------------------------------------------

               Exchange (Build_ARP, Address_Reply, Found, Queue, Slot);
               Harness.Check
                 (Found,
                  "the peer answered an address resolution request, so a"
                  & " frame this code built left the device, crossed the"
                  & " wire, was accepted by a stack that had never heard of"
                  & " it, and was answered");

               if not Found then
                  Harness.Skip
                    ("everything after address resolution",
                     "nothing on the wire is answering, so the checks that"
                     & " depend on a peer cannot say anything");
               else
                  declare
                     Answered : NIC.MAC_Address;
                  begin
                     for Index in 1 .. 6 loop
                        Answered (Index) := Arrived (Queue, Slot, 21 + Index);
                     end loop;
                     Harness.Check
                       (Answered = Peer_MAC,
                        "and the answer carries the address the harness"
                        & " gave that peer, so this is the intended peer"
                        & " and not whatever else shares the wire");
                  end;

                  ---------------------------------------------------
                  --  A header checksum
                  ---------------------------------------------------

                  Exchange (Build_Echo, Echo_Reply, Found, Queue, Slot);
                  Harness.Check
                    (Found,
                     "the peer replied to an echo request, which it does"
                     & " only for a frame whose IPv4 header checksum is"
                     & " right — a wrong one is dropped without complaint");

                  ---------------------------------------------------
                  --  A checksum over a header that is not sent
                  ---------------------------------------------------

                  Exchange (Build_UDP, Port_Unreachable, Found, Queue, Slot);
                  Harness.Check
                    (Found,
                     "a datagram to a closed port drew an unreachable"
                     & " report, so the UDP checksum was right: it is"
                     & " computed over the addresses and the protocol as"
                     & " well as the datagram, and none of those are in the"
                     & " bytes being summed");

                  ---------------------------------------------------
                  --  The same again, where it is not optional
                  ---------------------------------------------------

                  Exchange (Build_SYN, Connection_Refused, Found, Queue, Slot);
                  Harness.Check
                    (Found,
                     "a connection attempt to a closed port was refused"
                     & " with a reset, so a segment this code built was"
                     & " parsed and answered by a real stack — the last"
                     & " thing a loopback can never establish");

                  ---------------------------------------------------
                  --  Which queue a frame from outside lands on
                  ---------------------------------------------------

                  --  Scaling needs two things that read as unrelated and
                  --  are not. The longer descriptor layout, because the
                  --  short one has nowhere to report which queue was
                  --  chosen. And the packet checksum switched off, because
                  --  the hash goes in the four bytes the checksum would
                  --  occupy — so a device can report one or the other and
                  --  never both. A driver that wants scaling gives up
                  --  having the checksum handed to it, and a driver that
                  --  leaves the checksum on has quietly asked for one
                  --  queue.
                  Reg.Write_32
                    (BAR, NIC.Receive_Filter_Control_Register,
                     NIC.Extended_Descriptors);
                  Reg.Write_32
                    (BAR, NIC.Receive_Checksum_Register,
                     NIC.Checksum_In_Descriptor_Off);
                  Extended := True;

                  NIC.Set_Hash_Key (BAR, 16#5A5A_1234#);
                  Reg.Write_32
                    (BAR, NIC.Multiple_Queue_Register,
                     NIC.Multiple_Queue_Enable or NIC.Hash_Field_IPv4
                     or NIC.Hash_Field_IPv4_TCP);

                  for Target in NIC.Queue_Index loop
                     NIC.Steer_Everything_To (BAR, Target);
                     Exchange (Build_Echo, Echo_Reply, Found, Queue, Slot);
                     Harness.Check
                       (Found,
                        "with the whole redirection table pointing at queue"
                        & NIC.Queue_Index'Image (Target)
                        & " a reply still arrives");
                     if Found then
                        Harness.Check
                          (Queue = Target,
                           "and it arrives on queue"
                           & NIC.Queue_Index'Image (Target)
                           & ", so the device hashed a frame from the wire"
                           & " and read the table — which it will not do"
                           & " for a frame it sent itself");
                     end if;
                  end loop;
               end if;
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   Harness.Report ("e1000e_peer_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_peer_tests");
end E1000E_Peer_Tests;
