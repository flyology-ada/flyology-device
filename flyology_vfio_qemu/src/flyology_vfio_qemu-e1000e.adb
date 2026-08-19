with Flyology_VFIO.Registers;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_VFIO_QEMU.E1000E is

   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type SSE.Storage_Offset;

   --  Descriptor bytes. Volatile because the device writes them: a status
   --  byte a driver polls is memory changed by hardware, and nothing else
   --  in the program tells the optimiser so.
   type Byte_Array is array (Natural range <>) of U8 with Volatile;

   procedure Put_64 (Base : System.Address; At_Offset : Natural; Value : U64);
   procedure Put_Address
     (Base : System.Address; At_Offset : Natural; Value : Device_Address);
   procedure Put_16 (Base : System.Address; At_Offset : Natural; Value : U16);
   procedure Put_8 (Base : System.Address; At_Offset : Natural; Value : U8);
   procedure Put_32 (Base : System.Address; At_Offset : Natural; Value : U32);
   function Get_16 (Base : System.Address; At_Offset : Natural) return U16;
   function Get_8 (Base : System.Address; At_Offset : Natural) return U8;

   ------------
   -- Put_64 --
   ------------

   --  Byte by byte rather than through an overlay, because a descriptor is
   --  a little-endian layout defined by a datasheet and an overlay would
   --  silently reverse it on a big-endian host.


   --  Writes a device address into a descriptor.
   --
   --  The one place an address stops being an address and becomes eight
   --  bytes, which is why the conversion lives here under a name rather
   --  than scattered through the call sites as U64 (...) — each of those
   --  would be a place the distinction could be dropped without anyone
   --  reading it as a decision.
   procedure Put_Address
     (Base : System.Address; At_Offset : Natural; Value : Device_Address) is
   begin
      Put_64 (Base, At_Offset, U64 (Value));
   end Put_Address;

   ------------
   -- Put_64 --
   ------------

   procedure Put_64 (Base : System.Address; At_Offset : Natural; Value : U64)
   is
      Bytes : Byte_Array (0 .. 7) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      for Index in Bytes'Range loop
         Bytes (Index) :=
           U8 (Interfaces.Shift_Right (Value, 8 * Index) and 16#FF#);
      end loop;
   end Put_64;

   ------------
   -- Put_16 --
   ------------

   procedure Put_32 (Base : System.Address; At_Offset : Natural; Value : U32)
   is
      Cell : Byte_Array (0 .. 3) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      for Index in Cell'Range loop
         Cell (Index) :=
           U8 (Interfaces.Shift_Right (Value, 8 * Index) and 16#FF#);
      end loop;
   end Put_32;

   -----------
   -- Put_8 --
   -----------

   procedure Put_8 (Base : System.Address; At_Offset : Natural; Value : U8)
   is
      Cell : Byte_Array (0 .. 0) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      Cell (0) := Value;
   end Put_8;

   ------------
   -- Put_16 --
   ------------

   procedure Put_16 (Base : System.Address; At_Offset : Natural; Value : U16)
   is
      Bytes : Byte_Array (0 .. 1) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      Bytes (0) := U8 (Value and 16#FF#);
      Bytes (1) := U8 (Interfaces.Shift_Right (Value, 8) and 16#FF#);
   end Put_16;

   ------------
   -- Get_16 --
   ------------

   function Get_16 (Base : System.Address; At_Offset : Natural) return U16 is
      Bytes : Byte_Array (0 .. 1) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      return U16 (Bytes (0)) or Interfaces.Shift_Left (U16 (Bytes (1)), 8);
   end Get_16;

   -----------
   -- Get_8 --
   -----------

   function Get_8 (Base : System.Address; At_Offset : Natural) return U8 is
      Bytes : Byte_Array (0 .. 0) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      return Bytes (0);
   end Get_8;

   procedure Wait_Microseconds (Count : Interfaces.C.unsigned)
     with Import, Convention => C, External_Name => "usleep";

   Hex_Digits : constant String := "0123456789abcdef";

   ------------------------
   -- Hardware_Address --
   ------------------------

   function Hardware_Address (BAR : Regions.Window) return MAC_Address is
      Low  : constant U32 := Reg.Read_32 (BAR, Receive_Address_Low);
      High : constant U32 := Reg.Read_32 (BAR, Receive_Address_High);
   begin
      --  The wire order is little-endian within each half, which is not
      --  something a reader should have to infer from the register names.
      return
        [1 => U8 (Low and 16#FF#),
         2 => U8 (Interfaces.Shift_Right (Low, 8) and 16#FF#),
         3 => U8 (Interfaces.Shift_Right (Low, 16) and 16#FF#),
         4 => U8 (Interfaces.Shift_Right (Low, 24) and 16#FF#),
         5 => U8 (High and 16#FF#),
         6 => U8 (Interfaces.Shift_Right (High, 8) and 16#FF#)];
   end Hardware_Address;

   ------------------------------
   -- Hardware_Address_Valid --
   ------------------------------

   function Hardware_Address_Valid (BAR : Regions.Window) return Boolean is
     ((Reg.Read_32 (BAR, Receive_Address_High) and Receive_Address_Valid)
        /= 0);

   -----------
   -- Image --
   -----------

   function Image (Address : MAC_Address) return String is
      Text : String (1 .. 17);
      At_Position : Natural := 1;
   begin
      for Index in Address'Range loop
         Text (At_Position) :=
           Hex_Digits (Natural (Interfaces.Shift_Right (Address (Index), 4))
                       + 1);
         Text (At_Position + 1) :=
           Hex_Digits (Natural (Address (Index) and 16#F#) + 1);
         if Index < Address'Last then
            Text (At_Position + 2) := ':';
         end if;
         At_Position := At_Position + 3;
      end loop;
      return Text;
   end Image;

   -----------
   -- Value --
   -----------

   function Value (Text : String) return MAC_Address is
      Result      : MAC_Address := [others => 0];
      Index       : Natural := 0;
      Digit       : Natural := 0;
      Accumulated : U8 := 0;

      function Nibble (Symbol : Character) return U8;

      ------------
      -- Nibble --
      ------------

      function Nibble (Symbol : Character) return U8 is
      begin
         case Symbol is
            when '0' .. '9' =>
               return U8 (Character'Pos (Symbol) - Character'Pos ('0'));
            when 'a' .. 'f' =>
               return U8 (Character'Pos (Symbol) - Character'Pos ('a') + 10);
            when 'A' .. 'F' =>
               return U8 (Character'Pos (Symbol) - Character'Pos ('A') + 10);
            when others =>
               raise Device_Not_Available with
                 """" & Text & """ is not a hardware address: '" & Symbol
                 & "' is not a hexadecimal digit";
         end case;
      end Nibble;

   begin
      for Symbol of Text loop
         if Symbol = ':' or else Symbol = '-' then
            if Digit /= 2 then
               raise Device_Not_Available with
                 """" & Text & """ is not a hardware address";
            end if;
            Digit := 0;
         elsif Digit = 0 then
            Index := Index + 1;
            if Index > Result'Last then
               raise Device_Not_Available with
                 """" & Text & """ has too many octets to be a hardware"
                 & " address";
            end if;
            Accumulated := Nibble (Symbol) * 16;
            Digit := 1;
         else
            Accumulated := Accumulated + Nibble (Symbol);
            Result (Index) := Accumulated;
            Digit := 2;
         end if;
      end loop;

      if Index /= Result'Last then
         raise Device_Not_Available with
           """" & Text & """ has" & Natural'Image (Index)
           & " octets rather than six";
      end if;
      return Result;
   end Value;

   ---------------
   -- Read_PHY --
   ---------------

   --  The request names the register, the physical-layer chip's own
   --  address on that small bus, and the operation; the device clears the
   --  ready bit while it works and sets it again with the answer in the
   --  low half of the very same register.
   PHY_Address_Shift  : constant := 21;
   PHY_Register_Shift : constant := 16;
   PHY_Read_Opcode    : constant U32 := 2 * 2 ** 26;
   PHY_Ready          : constant U32 := 2 ** 28;
   PHY_Error          : constant U32 := 2 ** 30;

   --  The internal chip is always at address one on that bus.
   PHY_Internal : constant U32 := 1;

   function Read_PHY
     (BAR      : Regions.Window;
      Number   : PHY_Register;
      Attempts : Positive := 20_000) return U16
   is
      Request : constant U32 :=
        PHY_Read_Opcode
        or Interfaces.Shift_Left (PHY_Internal, PHY_Address_Shift)
        or Interfaces.Shift_Left (U32 (Number), PHY_Register_Shift);
      Polls : Natural := 0;
      Seen  : U32;
   begin
      Reg.Write_Release_32 (BAR, MDI_Control_Register, Request);

      loop
         Seen := Reg.Read_Acquire_32 (BAR, MDI_Control_Register);
         exit when (Seen and PHY_Ready) /= 0;
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the device never reported a physical-layer read of register"
              & PHY_Register'Image (Number) & " as done after"
              & Natural'Image (Attempts) & " polls";
         end if;
      end loop;

      return U16 (Seen and 16#FFFF#);
   end Read_PHY;

   -----------------------
   -- PHY_Read_Failed --
   -----------------------

   function PHY_Read_Failed (BAR : Regions.Window) return Boolean is
     ((Reg.Read_32 (BAR, MDI_Control_Register) and PHY_Error) /= 0);

   ------------------
   -- Read_EEPROM --
   ------------------

   EEPROM_Start        : constant U32 := 2 ** 0;
   EEPROM_Done         : constant U32 := 2 ** 1;
   EEPROM_Address_Shift : constant := 2;
   EEPROM_Data_Shift    : constant := 16;

   function Read_EEPROM
     (BAR      : Regions.Window;
      Word     : Natural;
      Attempts : Positive := 20_000) return U16
   is
      Request : constant U32 :=
        EEPROM_Start
        or Interfaces.Shift_Left (U32 (Word), EEPROM_Address_Shift);
      Polls : Natural := 0;
      Seen  : U32;
   begin
      Reg.Write_Release_32 (BAR, EEPROM_Read_Register, Request);

      loop
         Seen := Reg.Read_Acquire_32 (BAR, EEPROM_Read_Register);
         exit when (Seen and EEPROM_Done) /= 0;
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the device never reported reading configuration word"
              & Natural'Image (Word) & " as done after"
              & Natural'Image (Attempts) & " polls";
         end if;
      end loop;

      return U16 (Interfaces.Shift_Right (Seen, EEPROM_Data_Shift)
                  and 16#FFFF#);
   end Read_EEPROM;

   ----------------------
   -- Start_Receiving --
   ----------------------

   procedure Start_Receiving
     (BAR          : Regions.Window;
      Ring         : Ring_Location;
      Buffers      : Device_Address;
      Buffer_Bytes : Positive := Receive_Buffer_Bytes)
   is
   begin
      --  Every descriptor is given its buffer and cleared before the device
      --  is told the ring exists. The device starts consuming descriptors
      --  as soon as the tail moves, so a half-built ring is a device
      --  writing into whatever address a descriptor happened to hold.
      for Slot in 0 .. Ring.Count - 1 loop
         declare
            At_Offset : constant Natural := Slot * Descriptor_Bytes;
            Blank : Byte_Array (0 .. Descriptor_Bytes - 1) with Import,
              Address => Ring.Host + SSE.Storage_Offset (At_Offset);
         begin
            Blank := (others => 0);
            Put_Address
              (Ring.Host, At_Offset,
               Buffers
               + Device_Address (Slot) * Device_Address (Buffer_Bytes));
         end;
      end loop;

      declare
         Base : constant Natural := Receive_Ring_Base (Ring.Queue);
      begin
         Reg.Write_32 (BAR, Reg.Offset (Base),
                       Low_Half (Ring.Device));
         Reg.Write_32 (BAR, Reg.Offset (Base + Ring_Base_High),
                       High_Half (Ring.Device));
         Reg.Write_32 (BAR, Reg.Offset (Base + Ring_Length),
                       U32 (Ring.Count * Descriptor_Bytes));
         Reg.Write_32 (BAR, Reg.Offset (Base + Ring_Head), 0);
      end;

      --  Enabling before advancing the tail, so the device is running by
      --  the time it is given descriptors to run on.
      Reg.Write_32
        (BAR, Receive_Control_Register,
         Receive_Enable or Receive_Broadcast or Receive_Strip_CRC);

      --  The tail names the descriptor after the last one the driver owns,
      --  so a full ring points one short of itself.
      Reg.Write_Release_32
        (BAR, Reg.Offset (Receive_Ring_Base (Ring.Queue) + Ring_Tail),
         U32 (Ring.Count - 1));
   end Start_Receiving;

   -------------------------
   -- Start_Transmitting --
   -------------------------

   procedure Start_Transmitting
     (BAR : Regions.Window; Ring : Ring_Location)
   is
      Whole : Byte_Array (0 .. Ring.Count * Descriptor_Bytes - 1)
        with Import, Address => Ring.Host;
   begin
      Whole := (others => 0);

      declare
         Base : constant Natural := Transmit_Ring_Base (Ring.Queue);
      begin
         Reg.Write_32 (BAR, Reg.Offset (Base),
                       Low_Half (Ring.Device));
         Reg.Write_32 (BAR, Reg.Offset (Base + Ring_Base_High),
                       High_Half (Ring.Device));
         Reg.Write_32 (BAR, Reg.Offset (Base + Ring_Length),
                       U32 (Ring.Count * Descriptor_Bytes));
         Reg.Write_32 (BAR, Reg.Offset (Base + Ring_Head), 0);
         Reg.Write_32 (BAR, Reg.Offset (Base + Ring_Tail), 0);
      end;

      --  The inter-packet gap the datasheet gives for copper gigabit:
      --  eight, eight and six, in three fields ten bits apart. What was
      --  here set the second field to a hundred and twenty-eight and the
      --  third to nothing, because the bit meant for the second field's low
      --  end was written four places too high. Nothing could see it: the
      --  gap governs how long the device waits between frames on a shared
      --  medium, and an emulated point-to-point link never waits.
      Reg.Write_32 (BAR, Transmit_Gap_Register, 16#0060_2008#);

      Reg.Write_Release_32
        (BAR, Transmit_Control_Register,
         Transmit_Enable or Transmit_Pad_Short
         or Interfaces.Shift_Left (16#0F#, 4)
         or Interfaces.Shift_Left (16#40#, 12));
   end Start_Transmitting;

   --------------
   -- Transmit --
   --------------

   procedure Transmit
     (BAR      : Regions.Window;
      Ring     : Ring_Location;
      Slot     : Natural;
      Frame    : Device_Address;
      Length   : Positive;
      Attempts : Positive := 20_000)
   is
   begin
      Transmit (BAR, Ring, Slot, Frame, Length,
                Options => (others => <>), Attempts => Attempts);
   end Transmit;

   ------------------
   -- Transmit --
   ------------------

   procedure Transmit
     (BAR      : Regions.Window;
      Ring     : Ring_Location;
      Slot     : Natural;
      Frame    : Device_Address;
      Length   : Positive;
      Options  : Transmit_Options;
      Attempts : Positive := 20_000)
   is
      At_Offset : constant Natural := Slot * Descriptor_Bytes;
      Polls     : Natural := 0;
   begin
      declare
         Blank : Byte_Array (0 .. Descriptor_Bytes - 1) with Import,
           Address => Ring.Host + SSE.Storage_Offset (At_Offset);
      begin
         Blank := (others => 0);
      end;

      Put_Address (Ring.Host, At_Offset, Frame);
      Put_16 (Ring.Host, At_Offset + 8, U16 (Length));

      if Options.Insert_Checksum then
         --  Where to start summing goes in one byte and where to put the
         --  answer in another, and they are eleven bytes apart in the
         --  descriptor with the command between them. Both are offsets from
         --  the start of the frame, not from the start of the header being
         --  summed, which is the reading that produces a checksum computed
         --  over the right bytes and written into the wrong place.
         Put_8 (Ring.Host, At_Offset + 10, U8 (Options.Checksum_Offset));
         Put_8 (Ring.Host, At_Offset + 13, U8 (Options.Checksum_Start));
      end if;

      if Options.Insert_VLAN then
         Put_16 (Ring.Host, At_Offset + 14, Options.VLAN_Tag);
      end if;

      declare
         Command : Byte_Array (0 .. 0) with Import,
           Address => Ring.Host + SSE.Storage_Offset (At_Offset + 11);
      begin
         Command (0) := Transmit_End_Of_Packet or Transmit_Insert_CRC
                        or Transmit_Report_Status
                        or (if Options.Insert_Checksum
                            then Transmit_Insert_Checksum else 0)
                        or (if Options.Insert_VLAN
                            then Transmit_Insert_VLAN else 0);
      end;

      --  The doorbell. A release store, because every byte of the
      --  descriptor and of the frame it points at must be visible to the
      --  device before the device is told the descriptor is ready.
      Reg.Write_Release_32
        (BAR, Reg.Offset (Transmit_Ring_Base (Ring.Queue) + Ring_Tail),
         U32 ((Slot + 1) mod Ring.Count));

      loop
         exit when (Get_8 (Ring.Host, At_Offset + 12) and Descriptor_Done)
                     /= 0;
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the device did not report finishing with a transmit"
              & " descriptor after" & Natural'Image (Attempts) & " polls."
              & " It writes that report into the descriptor by DMA, so an"
              & " unreachable ring looks exactly like this. Check bus"
              & " mastering and the address the ring was given.";
         end if;
      end loop;
   end Transmit;

   ---------------------
   -- Peek_Received --
   ---------------------

   function Peek_Received
     (Ring   : Ring_Location;
      Slot   : Natural;
      Format : Descriptor_Format := Legacy) return Received_Frame
   is
      At_Offset : constant Natural := Slot * Descriptor_Bytes;
      Status    : constant U8 := Get_8 (Ring.Host, At_Offset + 12);
   begin
      --  The done bit is what says the length, the errors and the frame
      --  itself have been written. Ordering the loads after it is the read
      --  side of the release the doorbell writes perform, and it has no
      --  observable effect under emulation.
      Reg.Load_Fence;

      if Format = Legacy then
         return
           (Arrived  => (Status and Descriptor_Done) /= 0,
            Length   => Natural (Get_16 (Ring.Host, At_Offset + 8)),
            Complete => (Status and Descriptor_End_Of_Packet) /= 0,
            Errors   => Get_8 (Ring.Host, At_Offset + 13),
            Status   => Status,
            VLAN_Tag => Get_16 (Ring.Host, At_Offset + 14),
            Checksum => Get_16 (Ring.Host, At_Offset + 10));
      end if;

      --  The longer layout puts status and errors in one thirty-two bit
      --  field rather than two bytes, and the errors at the far end of it.
      --  They land on the same bit positions once the field is taken apart,
      --  which is a kindness and not an accident.
      declare
         Extended_Status : constant U8 := Get_8 (Ring.Host, At_Offset + 8);
      begin
         return
           (Arrived  => (Extended_Status and Descriptor_Done) /= 0,
            Length   => Natural (Get_16 (Ring.Host, At_Offset + 12)),
            Complete =>
              (Extended_Status and Descriptor_End_Of_Packet) /= 0,
            Errors   => Get_8 (Ring.Host, At_Offset + 11),
            Status   => Extended_Status,
            VLAN_Tag => Get_16 (Ring.Host, At_Offset + 14),
            --  The second word holds the IP identification and then the
            --  checksum, so the checksum is its upper half. Reading the
            --  lower half returns the identification, which is a plausible
            --  number and never the right one.
            Checksum => Get_16 (Ring.Host, At_Offset + 6));
      end;
   end Peek_Received;

   ----------------------
   -- Await_Received --
   ----------------------

   function Await_Received
     (Ring     : Ring_Location;
      Slot     : Natural;
      Attempts : Positive := 20_000) return Received_Frame
   is
      Polls : Natural := 0;
      Seen  : Received_Frame;
   begin
      loop
         Seen := Peek_Received (Ring, Slot);
         exit when Seen.Arrived;
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "no frame arrived in receive descriptor"
              & Natural'Image (Slot) & " after"
              & Natural'Image (Attempts) & " polls.";
         end if;
      end loop;
      return Seen;
   end Await_Received;

   -------------------------
   -- Recycle_Received --
   -------------------------

   procedure Recycle_Received
     (BAR    : Regions.Window;
      Ring   : Ring_Location;
      Slot   : Natural;
      Buffer : Device_Address)
   is
      At_Offset : constant Natural := Slot * Descriptor_Bytes;
      Blank : Byte_Array (0 .. Descriptor_Bytes - 1) with Import,
        Address => Ring.Host + SSE.Storage_Offset (At_Offset);
   begin
      Blank := (others => 0);
      Put_Address (Ring.Host, At_Offset, Buffer);
      Reg.Write_Release_32
        (BAR, Reg.Offset (Receive_Ring_Base (Ring.Queue) + Ring_Tail),
         U32 (Slot));
   end Recycle_Received;

   -----------
   -- Reset --
   -----------

   procedure Reset (BAR : Regions.Window; Attempts : Positive := 20_000) is
      Polls : Natural := 0;
   begin
      --  The whole register is written rather than read and modified. A
      --  device control register is not a status register, so either would
      --  work here, but writing the reset bit alone is what the datasheet
      --  describes and it leaves nothing to a stale read.
      Reg.Write_Release_32 (BAR, Control_Register, Control_Reset);

      while (Reg.Read_Acquire_32 (BAR, Control_Register) and Control_Reset)
              /= 0
      loop
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the device had not finished resetting after"
              & Natural'Image (Attempts) & " polls; it clears the reset bit"
              & " itself when it is done, and the bit is still set.";
         end if;
      end loop;

      --  A device coming out of reset needs a moment before its registers
      --  read meaningfully; the datasheet asks for a millisecond.
      Wait_Microseconds (2_000);
   end Reset;

   --------------------------------
   -- Transmit_Segmented --
   --------------------------------

   procedure Transmit_Segmented
     (BAR      : Regions.Window;
      Ring     : Ring_Location;
      Slot     : Natural;
      Frame    : Device_Address;
      Context  : Transmit_Context;
      Attempts : Positive := 20_000)
   is
      Context_At : constant Natural := Slot * Descriptor_Bytes;
      Data_At    : constant Natural :=
        ((Slot + 1) mod Ring.Count) * Descriptor_Bytes;
      Total      : constant Natural :=
        Context.Header_Bytes + Context.Payload_Bytes;
      Polls      : Natural := 0;

      --  Bit twenty-nine says a descriptor is not the legacy kind, and bit
      --  twenty says it carries data. A descriptor with the first and not
      --  the second is a context descriptor: the same sixteen bytes, read
      --  as something else entirely.
      Extended    : constant U32 := 2 ** 29;
      Carries_Data : constant U32 := 2 ** 20;
      Report_Done : constant U32 := 2 ** 27;
      Last_Of_It  : constant U32 := 2 ** 24;
      Add_FCS     : constant U32 := 2 ** 25;
      Cut_It_Up   : constant U32 := 2 ** 26;
      Maintain_IP  : constant U32 := 2 ** 25;
      Maintain_TCP : constant U32 := 2 ** 24;
   begin
      declare
         Blank : Byte_Array (0 .. Descriptor_Bytes - 1) with Import,
           Address => Ring.Host + SSE.Storage_Offset (Context_At);
      begin
         Blank := (others => 0);
      end;

      Put_8 (Ring.Host, Context_At, U8 (Context.IP_Start));
      Put_8 (Ring.Host, Context_At + 1, U8 (Context.IP_Offset));
      Put_16 (Ring.Host, Context_At + 2, U16 (Context.IP_End));
      Put_8 (Ring.Host, Context_At + 4, U8 (Context.Transport_Start));
      Put_8 (Ring.Host, Context_At + 5, U8 (Context.Transport_Offset));
      Put_16 (Ring.Host, Context_At + 6, U16 (Context.Transport_End));

      Put_32
        (Ring.Host, Context_At + 8,
         U32 (Context.Payload_Bytes)
         or Extended
         or (if Context.Segmenting then Cut_It_Up else 0)
         or (if Context.Over_IPv4 then Maintain_IP else 0)
         or (if Context.Over_TCP then Maintain_TCP else 0));

      Put_8 (Ring.Host, Context_At + 13, U8 (Context.Header_Bytes));
      Put_16 (Ring.Host, Context_At + 14, U16 (Context.Segment_Bytes));

      declare
         Blank : Byte_Array (0 .. Descriptor_Bytes - 1) with Import,
           Address => Ring.Host + SSE.Storage_Offset (Data_At);
      begin
         Blank := (others => 0);
      end;

      Put_Address (Ring.Host, Data_At, Frame);
      Put_32
        (Ring.Host, Data_At + 8,
         U32 (Total)
         or Extended or Carries_Data
         or Report_Done or Last_Of_It or Add_FCS
         or (if Context.Segmenting then Cut_It_Up else 0));

      --  The options byte, which is where a data descriptor asks for the
      --  checksums the context descriptor described. Segmentation without
      --  them produces frames with the template's checksum repeated.
      Put_8
        (Ring.Host, Data_At + 13,
         (if Context.Over_IPv4 then 1 else 0)
         or (if Context.Over_TCP or else Context.Segmenting then 2 else 0));

      Reg.Write_Release_32
        (BAR, Reg.Offset (Transmit_Ring_Base (Ring.Queue) + Ring_Tail),
         U32 ((Slot + 2) mod Ring.Count));

      loop
         exit when (Get_8 (Ring.Host, Data_At + 12) and Descriptor_Done) /= 0;
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the device did not report finishing with a segmented"
              & " transmit after" & Natural'Image (Attempts) & " polls";
         end if;
      end loop;
   end Transmit_Segmented;

   --------------
   -- Stop --
   --------------

   procedure Stop (BAR : Regions.Window) is
   begin
      Reg.Write_32 (BAR, Receive_Control_Register, 0);
      Reg.Write_32 (BAR, Transmit_Control_Register, 0);
      --  Read something back, so the writes have reached the device before
      --  the caller releases the memory it was writing into.
      if Reg.Read_Acquire_32 (BAR, Status_Register) = 16#FFFF_FFFF# then
         raise Device_Misbehaved with "the device stopped answering";
      end if;
   end Stop;

   --------------------------
   -- Wait_For_Link --
   --------------------------

   function Wait_For_Link
     (BAR : Regions.Window; Attempts : Positive := 20_000) return Boolean
   is
      Polls : Natural := 0;
   begin
      --  Asking for the link is a bit in the control register, and getting
      --  one is a bit in the status register that appears some time later:
      --  the two ends have to agree a speed first, and that is a
      --  negotiation with its own timer. A driver that writes the first bit
      --  and transmits immediately transmits into a link that is not up.
      Reg.Write_32
        (BAR, Control_Register,
         Reg.Read_32 (BAR, Control_Register) or Control_Set_Link_Up);

      loop
         if (Reg.Read_Acquire_32 (BAR, Status_Register) and Status_Link_Up)
              /= 0
         then
            return True;
         end if;
         Polls := Polls + 1;
         exit when Polls >= Attempts;
         Wait_Microseconds (100);
      end loop;
      return False;
   end Wait_For_Link;

   -------------------------------------
   -- Receive_Buffer_Size_Bits --
   -------------------------------------

   function Receive_Buffer_Size_Bits (Bytes : Positive) return U32 is
   begin
      case Bytes is
         when 2048  => return 0;
         when 1024  => return Interfaces.Shift_Left (1, 16);
         when 512   => return Interfaces.Shift_Left (2, 16);
         when 256   => return Interfaces.Shift_Left (3, 16);
         when 16384 =>
            return Interfaces.Shift_Left (1, 16) or Receive_Buffer_Extend;
         when 8192  =>
            return Interfaces.Shift_Left (2, 16) or Receive_Buffer_Extend;
         when 4096  =>
            return Interfaces.Shift_Left (3, 16) or Receive_Buffer_Extend;
         when others =>
            raise Device_Misused with
              "a receive buffer of" & Positive'Image (Bytes)
              & " bytes is not a size the control register can name";
      end case;
   end Receive_Buffer_Size_Bits;

   ---------------------------------
   -- Clear_Multicast_Table --
   ---------------------------------

   procedure Clear_Multicast_Table (BAR : Regions.Window) is
   begin
      for Index in 0 .. Multicast_Table_Entries - 1 loop
         Reg.Write_32
           (BAR, Reg.Offset (Multicast_Table_Register + 4 * Index), 0);
      end loop;
   end Clear_Multicast_Table;

   --------------------------
   -- Multicast_Bit --
   --------------------------

   function Multicast_Bit
     (Address : MAC_Address;
      Offset  : Multicast_Offset := From_Bit_47) return Natural
   is
      --  The hash is taken from the last two bytes of the address, read as
      --  one sixteen-bit number, shifted down by an amount the offset
      --  chooses, and cut to twelve bits. Note that the choices are not
      --  evenly spaced: three of them step by one and the last steps by
      --  two, which is in the specification and looks like a mistake until
      --  you check.
      Shift : constant Natural :=
        (case Offset is
            when From_Bit_47 => 4,
            when From_Bit_46 => 3,
            when From_Bit_45 => 2,
            when From_Bit_43 => 0);
      Pair : constant U32 :=
        Interfaces.Shift_Left (U32 (Address (6)), 8) or U32 (Address (5));
   begin
      return Natural (Interfaces.Shift_Right (Pair, Shift) and 16#FFF#);
   end Multicast_Bit;

   -------------------------
   -- Set_Multicast --
   -------------------------

   procedure Set_Multicast
     (BAR     : Regions.Window;
      Address : MAC_Address;
      Allowed : Boolean;
      Offset  : Multicast_Offset := From_Bit_47)
   is
      Bit   : constant Natural := Multicast_Bit (Address, Offset);
      Where : constant Reg.Offset :=
        Reg.Offset (Multicast_Table_Register + 4 * (Bit / 32));
      Mask  : constant U32 := Interfaces.Shift_Left (1, Bit mod 32);
      Held  : constant U32 := Reg.Read_32 (BAR, Where);
   begin
      Reg.Write_32
        (BAR, Where, (if Allowed then Held or Mask else Held and not Mask));
   end Set_Multicast;

   -------------------------------
   -- Clear_VLAN_Filters --
   -------------------------------

   procedure Clear_VLAN_Filters (BAR : Regions.Window) is
   begin
      for Index in 0 .. VLAN_Filter_Entries - 1 loop
         Reg.Write_32
           (BAR, Reg.Offset (VLAN_Filter_Table_Register + 4 * Index), 0);
      end loop;
   end Clear_VLAN_Filters;

   ---------------------------
   -- Set_VLAN_Filter --
   ---------------------------

   procedure Set_VLAN_Filter
     (BAR        : Regions.Window;
      Identifier : VLAN_Identifier;
      Allowed    : Boolean)
   is
      Where : constant Reg.Offset :=
        Reg.Offset (VLAN_Filter_Table_Register + 4 * (Natural (Identifier) / 32));
      Mask  : constant U32 :=
        Interfaces.Shift_Left (1, Natural (Identifier) mod 32);
      Held  : constant U32 := Reg.Read_32 (BAR, Where);
   begin
      Reg.Write_32
        (BAR, Where, (if Allowed then Held or Mask else Held and not Mask));
   end Set_VLAN_Filter;

   ------------------------------
   -- VLAN_Filter_Allows --
   ------------------------------

   function VLAN_Filter_Allows
     (BAR : Regions.Window; Identifier : VLAN_Identifier) return Boolean
   is
      Where : constant Reg.Offset :=
        Reg.Offset (VLAN_Filter_Table_Register + 4 * (Natural (Identifier) / 32));
      Mask  : constant U32 :=
        Interfaces.Shift_Left (1, Natural (Identifier) mod 32);
   begin
      return (Reg.Read_32 (BAR, Where) and Mask) /= 0;
   end VLAN_Filter_Allows;

   ---------------------------------
   -- Steer_Everything_To --
   ---------------------------------

   procedure Steer_Everything_To
     (BAR : Regions.Window; Queue : Queue_Index)
   is
      --  One byte per entry, of which this controller reads the *highest*
      --  bit — not the lowest, which is where a reader who knows the field
      --  is one bit wide will put it, and which produces a table that reads
      --  back exactly as written and steers nothing. Written four entries
      --  at a time because the register file is thirty-two bits wide
      --  however narrow the field is.
      Cell : constant U32 := Interfaces.Shift_Left (U32 (Queue), 7);
      Word : constant U32 :=
        Cell
        or Interfaces.Shift_Left (Cell, 8)
        or Interfaces.Shift_Left (Cell, 16)
        or Interfaces.Shift_Left (Cell, 24);
   begin
      for Index in 0 .. Redirection_Table_Bytes / 4 - 1 loop
         Reg.Write_32
           (BAR, Reg.Offset (Redirection_Table_Register + 4 * Index), Word);
      end loop;
   end Steer_Everything_To;

   -------------------------
   -- Set_Hash_Key --
   -------------------------

   procedure Set_Hash_Key (BAR : Regions.Window; Seed : U32) is
      Value : U32 := Seed;
   begin
      for Index in 0 .. Hash_Key_Bytes / 4 - 1 loop
         Reg.Write_32
           (BAR, Reg.Offset (Hash_Key_Register + 4 * Index), Value);
         --  Any spreading function will do: the key is a secret rather than
         --  a structure, and what matters for a test is that it is the same
         --  secret every run.
         Value := Value * 1_664_525 + 1_013_904_223;
      end loop;
   end Set_Hash_Key;

end Flyology_VFIO_QEMU.E1000E;
