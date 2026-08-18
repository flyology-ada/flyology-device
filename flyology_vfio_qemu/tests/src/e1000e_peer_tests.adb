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
--  Above the transport there is a further step, and this test takes it
--  itself rather than needing a program alongside. Those replies are ones a
--  stack produces on its own; nothing above the transport layer ever ran.
--  So the test opens a socket of its own with Flyology's socket interface
--  and binds it to a port on the peer's address, and then sends a datagram
--  to that port through the device it is driving.
--
--  The path that datagram takes is the point. It is built by hand here, put
--  on the wire by a driver in this repository, carried across a virtual
--  hub, received by the guest kernel on a different network card, routed up
--  through its UDP layer, delivered into a socket, read by an ordinary Ada
--  program, written back, and sent out again the same way in reverse. Both
--  ends are this process and nothing about the journey is shortened by
--  that: the two halves meet through a real stack and a real wire rather
--  than through a device agreeing with itself.
--
--  It is also the only place receive-side scaling can be observed, because
--  this device hashes frames arriving from outside and not frames it sent
--  itself.

with Ada.Calendar;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Flyology.IO.Sockets;
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
     (Address_Reply, Echo_Reply, Port_Unreachable, Connection_Refused,
      Socket_Answer, Handshake_Answer, Stream_Data, Any_Stream);

   package Sockets renames Flyology.IO.Sockets;
   use type Sockets.Selector_Status;
   use type Ada.Streams.Stream_Element_Offset;

   --  Where the socket half of this test listens, and the port the raw half
   --  sends from. Both are chosen here rather than left to the system so
   --  that a datagram going missing cannot be mistaken for one arriving
   --  somewhere unexpected.
   Echo_Port   : constant Sockets.Port := 7_777;
   Stream_Port : constant Sockets.Port := 7_778;
   Reply_Port  : constant := 5_002;

   --  A fresh source port every run, the way a real client picks one.
   --
   --  A fixed one looks tidier and is wrong: the connection this test opens
   --  outlives the test, because the far end keeps it a while after the
   --  near end has stopped existing. The next run reuses the same four
   --  addresses and ports, and its synchronise is answered not with an
   --  agreement but with a bare acknowledgement of the *previous*
   --  connection's sequence number — which is a stack defending itself
   --  against exactly this, and looks from here like the listener having
   --  gone deaf.
   Stream_From : constant U16 :=
     40_000 + U16 (Natural (Ada.Calendar.Seconds (Ada.Calendar.Clock))
                   mod 20_000);

   --  What the echo puts in front of what it was sent. A plain echo cannot
   --  be told apart from the request returning some other way — a device
   --  looping frames back, a hub reflecting them. A reply that differs from
   --  the request in a way only this program could produce can.
   Marker : constant String := "FLY:";

   --  The socket half. It binds before the raw half sends anything, and
   --  stops when asked, because a task still waiting on a socket would keep
   --  the program alive after its checks had finished.
   --  A count both halves of this test can reach. An entry would have done
   --  as well until the receiving loop moved into a nested procedure, where
   --  an accept is not allowed; a protected object has no such rule and
   --  answers while the task is busy rather than between its turns.
   protected Tally is
      procedure Add (Count : Natural);
      function Total return Natural;
      procedure Ask_To_Stop;
      function Stopping return Boolean;
   private
      Seen  : Natural := 0;
      Asked : Boolean := False;
   end Tally;

   protected body Tally is
      procedure Add (Count : Natural) is
      begin
         Seen := Seen + Count;
      end Add;

      function Total return Natural is (Seen);

      procedure Ask_To_Stop is
      begin
         Asked := True;
      end Ask_To_Stop;

      function Stopping return Boolean is (Asked);
   end Tally;

   task Echo_Socket is
      entry Listening;
   end Echo_Socket;

   task body Echo_Socket is
      Socket : Sockets.Socket_Type;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 2_048);
      Reply  : Ada.Streams.Stream_Element_Array (1 .. 2_048);
      Last   : Ada.Streams.Stream_Element_Offset;
      Sent   : Ada.Streams.Stream_Element_Offset;
      From   : Sockets.Endpoint;
      Asked  : Boolean := False;
   begin
      Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Set_Socket_Option
        (Socket, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Set_Socket_Option
        (Socket, (Name => Sockets.Receive_Timeout, Timeout => 0.25));
      Sockets.Bind_Socket
        (Socket, Sockets.Network_Endpoint (Sockets.Any_IPv4, Echo_Port));
      accept Listening;

      while not Asked loop
         begin
            Sockets.Receive_Socket (Socket, Buffer, Last, From);
            if Last >= Buffer'First then
               for Index in Marker'Range loop
                  Reply (Ada.Streams.Stream_Element_Offset
                           (Index - Marker'First + 1)) :=
                    Character'Pos (Marker (Index));
               end loop;
               Reply (Marker'Length + 1 .. Marker'Length + Last) :=
                 Buffer (1 .. Last);
               Sockets.Send_Socket
                 (Socket, Reply (1 .. Marker'Length + Last), Sent, From);
            end if;
         exception
            --  A receive that timed out rather than failing. There is no
            --  way to tell those apart through this interface, and for a
            --  test peer there is no need to.
            when others => null;
         end;

         Asked := Tally.Stopping;
      end loop;

      Sockets.Close_Socket (Socket);
   exception
      when others =>
         while not Tally.Stopping loop
            delay 0.1;
         end loop;
   end Echo_Socket;

   --  The connection half. Same idea as the datagram one and a much
   --  stronger claim: a connection has to be established before a byte can
   --  be sent, and establishing one means the other end agreed to a
   --  sequence number this test chose and acknowledged it.
   --
   --  It counts what it has received as well as echoing it, because the
   --  segmentation check below is about how much arrived rather than what
   --  came back: the device is handed one buffer and asked to turn it into
   --  frames, and the question is whether every byte of it reached a socket.
   task Echo_Stream is
      entry Listening;
   end Echo_Stream;

   task body Echo_Stream is
      Server   : Sockets.Socket_Type;
      Accepted : Sockets.Socket_Type;
      Buffer   : Ada.Streams.Stream_Element_Array (1 .. 4_096);
      Reply    : Ada.Streams.Stream_Element_Array (1 .. 4_200);
      Last     : Ada.Streams.Stream_Element_Offset;
      Sent     : Ada.Streams.Stream_Element_Offset;
      From     : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;
      Asked    : Boolean := False;

      Give_Up : Boolean := False;

      procedure Serve_One;

      procedure Serve_One is
         --  A receive that timed out and a peer that has finished both
         --  produce no bytes, and this interface cannot tell them apart.
         --  Treating the first as the second closes the connection under a
         --  peer that was only being slow — which is what happened here,
         --  and what the other end reported as a reset rather than as an
         --  echo. So an empty read is patience, and only a long run of them
         --  is an ending.
         Quiet : Natural := 0;
      begin
         while Quiet < 60 and then not Give_Up loop
            begin
               Sockets.Receive_Socket (Accepted, Buffer, Last);
               if Last >= Buffer'First then
                  Quiet := 0;
                  Tally.Add (Natural (Last));
                  for Index in Marker'Range loop
                     Reply (Ada.Streams.Stream_Element_Offset
                              (Index - Marker'First + 1)) :=
                       Character'Pos (Marker (Index));
                  end loop;
                  Reply (Marker'Length + 1 .. Marker'Length + Last) :=
                    Buffer (1 .. Last);
                  Sockets.Send_Socket
                    (Accepted, Reply (1 .. Marker'Length + Last), Sent);
               else
                  Quiet := Quiet + 1;
               end if;
            exception
               when others => Quiet := Quiet + 1;
            end;

            Give_Up := Tally.Stopping;
         end loop;
      end Serve_One;
   begin
      Sockets.Create_Socket (Server, Sockets.IPv4, Sockets.Socket_Stream);
      Sockets.Set_Socket_Option
        (Server, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket
        (Server, Sockets.Network_Endpoint (Sockets.Any_IPv4, Stream_Port));
      Sockets.Listen_Socket (Server);
      accept Listening;

      while not Asked loop
         Sockets.Accept_Socket (Server, Accepted, From, 0.25, Status);
         if Status = Sockets.Completed then
            Sockets.Set_Socket_Option
              (Accepted,
               (Name => Sockets.Receive_Timeout, Timeout => 0.25));
            Serve_One;
            Sockets.Close_Socket (Accepted);
         end if;

         Asked := Give_Up or else Tally.Stopping;
      end loop;

      Sockets.Close_Socket (Server);
   exception
      when others =>
         while not Tally.Stopping loop
            delay 0.1;
         end loop;
   end Echo_Stream;
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
               --  Large enough for a segmented payload and its template
               --  header. Everything else here fits in a frame; the one
               --  thing that does not is the whole point of the last check.
               Frame : array (0 .. 4_095) of U8
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

               --  A datagram aimed at the socket this same program has
               --  open. Nothing about it is special; the port is one the
               --  other half of this test is listening on rather than one
               --  nothing is.
               function Build_To_Socket return Positive is
                  Payload : constant String := "flyology-device";
                  Length  : constant Natural := 8 + Payload'Length;
               begin
                  Start_Frame (16#0800#);
                  Put_16_At (Trans_At, Reply_Port);
                  Put_16_At (Trans_At + 2, U16 (Echo_Port));
                  Put_16_At (Trans_At + 4, U16 (Length));
                  for Index in Payload'Range loop
                     Frame (Trans_At + 8 + Index - Payload'First) :=
                       U8 (Character'Pos (Payload (Index)));
                  end loop;
                  Put_16_At
                    (Trans_At + 6,
                     Folded (Word_Sum (Trans_At, Length)
                             + Pseudo_Header (17, U32 (Length))));
                  return Finish_IPv4 (17, Length);
               end Build_To_Socket;

               --  One TCP segment on the connection to the listener,
               --  with whatever flags and payload are asked for. Sequence
               --  and acknowledgement numbers are the caller's business,
               --  because getting them right is the thing being checked.
               function Build_Segment
                 (Flags   : U16;
                  Sequence : U32;
                  Acknowledge : U32;
                  Payload : String := "") return Positive
               is
                  Length : constant Natural := 20 + Payload'Length;
               begin
                  Start_Frame (16#0800#);
                  Put_16_At (Trans_At, Stream_From);
                  Put_16_At (Trans_At + 2, U16 (Stream_Port));
                  Put_32_At (Trans_At + 4, Sequence);
                  Put_32_At (Trans_At + 8, Acknowledge);
                  --  Five words of header in the high nibble; a zero there
                  --  is a segment every stack discards.
                  Put_16_At (Trans_At + 12, 16#5000# or Flags);
                  Put_16_At (Trans_At + 14, 8_192);
                  for Index in Payload'Range loop
                     Frame (Trans_At + 20 + Index - Payload'First) :=
                       U8 (Character'Pos (Payload (Index)));
                  end loop;
                  Put_16_At
                    (Trans_At + 16,
                     Folded (Word_Sum (Trans_At, Length)
                             + Pseudo_Header (6, U32 (Length))));
                  return Finish_IPv4 (6, Length);
               end Build_Segment;

               --  A template header followed by more payload than one frame
               --  can carry. The header is what every emitted frame starts
               --  from and the device rewrites the parts that differ; the
               --  length and both checksums are left as they are, because
               --  they cannot be right for every segment and the device is
               --  being asked to work them out.
               function Build_Large
                 (Sequence : U32; Acknowledge : U32; Payload : Natural)
                  return Positive
               is
                  Length : constant Natural := 20 + Payload;
               begin
                  Start_Frame (16#0800#);
                  Put_16_At (Trans_At, Stream_From);
                  Put_16_At (Trans_At + 2, U16 (Stream_Port));
                  Put_32_At (Trans_At + 4, Sequence);
                  Put_32_At (Trans_At + 8, Acknowledge);
                  Put_16_At (Trans_At + 12, 16#5018#);
                  Put_16_At (Trans_At + 14, 8_192);
                  for Index in 0 .. Payload - 1 loop
                     Frame (Trans_At + 20 + Index) :=
                       U8 (Character'Pos ('a') + U8 (Index mod 26));
                  end loop;
                  Frame (IP_At) := 16#45#;
                  Put_16_At (IP_At + 2, U16 (20 + Length));
                  Put_16_At (IP_At + 4, 16#ABCD#);
                  Frame (IP_At + 8) := 64;
                  Frame (IP_At + 9) := 6;
                  Put_32_At (IP_At + 12, Our_IP);
                  Put_32_At (IP_At + 16, Peer_IP);
                  return IP_At + 20 + Length;
               end Build_Large;

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
                     when Handshake_Answer =>
                        --  Synchronise and acknowledge together, from the
                        --  port the listener is on. Anything else on this
                        --  connection is not the second step.
                        return Word (12) = 16#0800#
                          and then Byte (IP_At + 9) = 6
                          and then Word (Trans_At) = U16 (Stream_Port)
                          and then Word (Trans_At + 2) = Stream_From
                          and then (Byte (Trans_At + 13) and 16#12#)
                                   = 16#12#;
                     when Stream_Data =>
                        --  Anything carrying payload on that connection.
                        return Word (12) = 16#0800#
                          and then Byte (IP_At + 9) = 6
                          and then Word (Trans_At) = U16 (Stream_Port)
                          and then Word (Trans_At + 2) = Stream_From
                          and then Natural (Word (IP_At + 2)) > 20 + 20;
                     when Any_Stream =>
                        return Word (12) = 16#0800#
                          and then Byte (IP_At + 9) = 6
                          and then Word (Trans_At) = U16 (Stream_Port)
                          and then Word (Trans_At + 2) = Stream_From;
                     when Socket_Answer =>
                        --  A datagram back to the port the raw half sent
                        --  from, which is a reply and not the request
                        --  returning: the request went the other way.
                        return Word (12) = 16#0800#
                          and then Byte (IP_At + 9) = 17
                          and then Word (Trans_At + 2) = Reply_Port
                          and then Word (Trans_At) = U16 (Echo_Port);
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
                        --  At most one pass over the ring per attempt.
                        --  Draining until a descriptor is not ready sounds
                        --  equivalent and is not: every descriptor handed
                        --  back becomes one the device may fill again
                        --  immediately, so on a busy wire the loop has
                        --  always got one more and never comes back.
                        for Walked in 1 .. Ring_Slots loop
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
                  --  All the way up to a socket, and back
                  ---------------------------------------------------

                  select
                     Echo_Socket.Listening;
                  or
                     delay 10.0;
                     Harness.Skip
                       ("the socket exchange",
                        "the datagram socket never came up");
                  end select;
                  Exchange (Build_To_Socket, Socket_Answer,
                            Found, Queue, Slot);
                  Harness.Check
                    (Found,
                     "a datagram built here, put on the wire by this"
                     & " driver, and addressed to a socket this same"
                     & " program has open came back — so it was carried"
                     & " across the hub, taken up through a kernel that"
                     & " knows nothing about any of this, delivered into"
                     & " the socket, and answered");

                  if Found then
                     declare
                        Payload_At : constant Natural := Trans_At + 8;
                        Marked : Boolean := True;
                     begin
                        for Index in Marker'Range loop
                           if Arrived
                                (Queue, Slot,
                                 Payload_At + Index - Marker'First)
                             /= U8 (Character'Pos (Marker (Index)))
                           then
                              Marked := False;
                           end if;
                        end loop;
                        Harness.Check
                          (Marked,
                           "and it carries what the socket put in front of"
                           & " it rather than only what was sent, so this"
                           & " is an answer from a program and not the"
                           & " request returning by some other path");
                     end;
                  end if;

                  ---------------------------------------------------
                  --  A connection, established by hand
                  ---------------------------------------------------

                  select
                     Echo_Stream.Listening;
                  or
                     delay 10.0;
                     Harness.Skip
                       ("the connection exchange",
                        "the listener never came up");
                  end select;
                  declare
                     Ours   : constant U32 := 16#0001_0000#;
                     Theirs : U32 := 0;
                     Sent_Text : constant String := "over-tcp";
                     Next_Sequence : U32 := 16#0001_0001#;
                  begin
                     Exchange (Build_Segment (16#02#, Ours, 0),
                               Handshake_Answer, Found, Queue, Slot);
                     Harness.Check
                       (Found,
                        "a listener this program opened answered a"
                        & " synchronise built by hand, so the first step of"
                        & " a connection completed across the wire");

                     if Found then
                        declare
                           function Long (Where : Natural) return U32
                           is (Interfaces.Shift_Left
                                 (U32 (Arrived (Queue, Slot, Where)), 24)
                               or Interfaces.Shift_Left
                                    (U32 (Arrived (Queue, Slot, Where + 1)),
                                     16)
                               or Interfaces.Shift_Left
                                    (U32 (Arrived (Queue, Slot, Where + 2)),
                                     8)
                               or U32 (Arrived (Queue, Slot, Where + 3)));
                           Acknowledged : constant U32 :=
                             Long (Trans_At + 8);
                        begin
                           Theirs := Long (Trans_At + 4);
                           Harness.Check
                             (Acknowledged = Ours + 1,
                              "and acknowledged exactly the sequence number"
                              & " this test chose, plus one — so the number"
                              & " went out, was understood, and came back"
                              & " incremented rather than echoed");
                        end;

                        --  Third step, then data on the same segment's
                        --  heels. A connection is open at this point and
                        --  every byte after it is ordinary traffic.
                        Send (Build_Segment (16#10#, Ours + 1, Theirs + 1));
                        Exchange
                          (Build_Segment (16#18#, Ours + 1, Theirs + 1,
                                          Sent_Text),
                           Stream_Data, Found, Queue, Slot);
                        Harness.Check
                          (Found,
                           "and data sent on it came back, having been"
                           & " read out of a socket and written into it"
                           & " again");
                        if not Found then
                           Harness.Note
                             ("the socket had seen"
                              & Natural'Image (Tally.Total)
                              & " bytes by then");
                           Exchange (Build_Segment (16#18#, Ours + 1,
                                                    Theirs + 1, "again"),
                                     Any_Stream, Found, Queue, Slot);
                           if Found then
                              Harness.Note
                                ("a segment came back with flags 0x"
                                 & Hex_16 (U16 (Arrived (Queue, Slot,
                                                         Trans_At + 13)))
                                 & " and total length"
                                 & Natural'Image
                                     (Natural (Arrived (Queue, Slot,
                                                        IP_At + 2)) * 256
                                      + Natural (Arrived (Queue, Slot,
                                                          IP_At + 3))));
                           else
                              Harness.Note ("nothing came back at all");
                           end if;
                           Found := False;
                        end if;

                        if Found then
                           declare
                              Payload_At : constant Natural := Trans_At + 20;
                              Marked : Boolean := True;
                           begin
                              for Index in Marker'Range loop
                                 if Arrived
                                      (Queue, Slot,
                                       Payload_At + Index - Marker'First)
                                   /= U8 (Character'Pos (Marker (Index)))
                                 then
                                    Marked := False;
                                 end if;
                              end loop;
                              Harness.Check
                                (Marked,
                                 "carrying what the socket put in front of"
                                 & " it");
                           end;

                           ---------------------------------------------
                           --  More than one frame's worth, in one go
                           ---------------------------------------------

                           declare
                              Bulk : constant := 4_000;
                              Segment : constant := 1_000;
                              Before : constant Natural := Tally.Total;
                              Length : constant Positive :=
                                Build_Large (Ours + 1
                                             + U32 (Sent_Text'Length),
                                             Theirs + 1, Bulk);
                              pragma Unreferenced (Length);
                              Cutting : constant NIC.Transmit_Context :=
                                (IP_Start         => IP_At,
                                 IP_Offset        => IP_At + 10,
                                 IP_End           => 0,
                                 Transport_Start  => Trans_At,
                                 Transport_Offset => Trans_At + 16,
                                 Transport_End    => 0,
                                 Header_Bytes     => Trans_At + 20,
                                 Payload_Bytes    => Bulk,
                                 Segment_Bytes    => Segment,
                                 others           => <>);
                              Arrived_Bytes : Natural := 0;
                           begin
                              Reg.Write_32
                                (BAR, NIC.Segmentation_Count_Register, 0);
                              NIC.Transmit_Segmented
                                (BAR, TX, TX_Slot, At_Device (Frame_At),
                                 Cutting);
                              TX_Slot := (TX_Slot + 2) mod Ring_Slots;

                              for Attempt in 1 .. 400 loop
                                 Arrived_Bytes := Tally.Total - Before;
                                 exit when Arrived_Bytes >= Bulk;
                                 delay 0.005;
                              end loop;

                              Harness.Note
                                ("the socket received"
                                 & Natural'Image (Arrived_Bytes)
                                 & " of" & Natural'Image (Bulk)
                                 & " bytes; the device counted"
                                 & U32'Image
                                     (Reg.Read_32
                                        (BAR,
                                         NIC.Segmentation_Count_Register))
                                 & " segmented packets and"
                                 & U32'Image
                                     (Reg.Read_32
                                        (BAR,
                                         NIC.Segmentation_Failed_Register))
                                 & " refusals");

                              Next_Sequence :=
                                Ours + 1 + U32 (Sent_Text'Length)
                                + U32 (Bulk);
                              Harness.Check
                                (Arrived_Bytes >= Bulk,
                                 "every byte of a payload four times larger"
                                 & " than a frame reached the socket, from"
                                 & " one buffer and one template header:"
                                 & " the device cut it up, advanced the"
                                 & " sequence number for each piece, fixed"
                                 & " both checksums, and the receiving"
                                 & " stack accepted the lot — which it does"
                                 & " not do for a segment that is wrong in"
                                 & " any of those");
                           end;
                        end if;

                        --  Tear the connection down with the sequence
                        --  number the far end is expecting. A reset that
                        --  names any other one is not believed — it is
                        --  answered with an acknowledgement instead, and
                        --  the connection stays up.
                        Send (Build_Segment (16#04#, Next_Sequence,
                                             Theirs + 1));
                     end if;
                  end;

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
                  --  Which descriptor layout the device writes cannot be
                  --  changed under a running receiver: the rings hold
                  --  descriptors of the old shape and the device would
                  --  start writing the new one into them. So the receiver
                  --  is stopped, the layout changed, and the rings built
                  --  again from the beginning.
                  Reg.Write_32 (BAR, NIC.Receive_Control_Register, 0);
                  Reg.Write_32
                    (BAR, NIC.Receive_Filter_Control_Register,
                     NIC.Extended_Descriptors);
                  Reg.Write_32
                    (BAR, NIC.Receive_Checksum_Register,
                     NIC.Checksum_In_Descriptor_Off);
                  for Each in NIC.Queue_Index loop
                     NIC.Start_Receiving
                       (BAR, RX (Each), Buffer_Device (Each, 0),
                        Buffer_Bytes);
                     RX_Slot (Each) := 0;
                  end loop;
                  Reg.Write_32
                    (BAR, NIC.Receive_Control_Register,
                     NIC.Receive_Enable or NIC.Receive_Broadcast
                     or NIC.Receive_Strip_CRC);
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

               --  Before the mapping goes away, not after.
               NIC.Stop (BAR);
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   --  A timed call rather than a plain one. A task that has already fallen
   --  over will never reach its accept, and a plain call would then wait
   --  for it for ever — turning a reported failure into a run that never
   --  finishes and says nothing at all, which is what happened here.
   Tally.Ask_To_Stop;
   Harness.Report ("e1000e_peer_tests");

exception
   when Error : Device_Not_Available =>
      Tally.Ask_To_Stop;
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_peer_tests");

   --  Anything else has to stop the tasks too. A program whose main body
   --  gave up while a task is still waiting on a socket does not exit: it
   --  waits for that task for ever, and a failure that would have been
   --  reported in a line becomes a run that says nothing and never ends.
   when Error : others =>
      Tally.Ask_To_Stop;
      Harness.Check
        (False,
         "the run ended early: "
         & Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_peer_tests");
end E1000E_Peer_Tests;
