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
   procedure Put_16 (Base : System.Address; At_Offset : Natural; Value : U16);
   function Get_16 (Base : System.Address; At_Offset : Natural) return U16;
   function Get_8 (Base : System.Address; At_Offset : Natural) return U8;

   ------------
   -- Put_64 --
   ------------

   --  Byte by byte rather than through an overlay, because a descriptor is
   --  a little-endian layout defined by a datasheet and an overlay would
   --  silently reverse it on a big-endian host.

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

   ----------------------
   -- Start_Receiving --
   ----------------------

   procedure Start_Receiving
     (BAR          : Regions.Window;
      Ring         : Ring_Location;
      Buffers      : U64;
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
            Put_64 (Ring.Host, At_Offset,
                    Buffers + U64 (Slot) * U64 (Buffer_Bytes));
         end;
      end loop;

      Reg.Write_32 (BAR, Receive_Base_Low_Register,
                    U32 (Ring.Device and 16#FFFF_FFFF#));
      Reg.Write_32 (BAR, Receive_Base_High_Register,
                    U32 (Interfaces.Shift_Right (Ring.Device, 32)));
      Reg.Write_32 (BAR, Receive_Length_Register,
                    U32 (Ring.Count * Descriptor_Bytes));
      Reg.Write_32 (BAR, Receive_Head_Register, 0);

      --  Enabling before advancing the tail, so the device is running by
      --  the time it is given descriptors to run on.
      Reg.Write_32
        (BAR, Receive_Control_Register,
         Receive_Enable or Receive_Broadcast or Receive_Strip_CRC);

      --  The tail names the descriptor after the last one the driver owns,
      --  so a full ring points one short of itself.
      Reg.Write_Release_32
        (BAR, Receive_Tail_Register, U32 (Ring.Count - 1));
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

      Reg.Write_32 (BAR, Transmit_Base_Low_Register,
                    U32 (Ring.Device and 16#FFFF_FFFF#));
      Reg.Write_32 (BAR, Transmit_Base_High_Register,
                    U32 (Interfaces.Shift_Right (Ring.Device, 32)));
      Reg.Write_32 (BAR, Transmit_Length_Register,
                    U32 (Ring.Count * Descriptor_Bytes));
      Reg.Write_32 (BAR, Transmit_Head_Register, 0);
      Reg.Write_32 (BAR, Transmit_Tail_Register, 0);

      --  The inter-packet gap the datasheet gives for copper gigabit.
      Reg.Write_32 (BAR, Transmit_Gap_Register, 8 or 16#0002_0000#);

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
      Frame    : U64;
      Length   : Positive;
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

      Put_64 (Ring.Host, At_Offset, Frame);
      Put_16 (Ring.Host, At_Offset + 8, U16 (Length));

      declare
         Command : Byte_Array (0 .. 0) with Import,
           Address => Ring.Host + SSE.Storage_Offset (At_Offset + 11);
      begin
         Command (0) := Transmit_End_Of_Packet or Transmit_Insert_CRC
                        or Transmit_Report_Status;
      end;

      --  The doorbell. A release store, because every byte of the
      --  descriptor and of the frame it points at must be visible to the
      --  device before the device is told the descriptor is ready.
      Reg.Write_Release_32
        (BAR, Transmit_Tail_Register,
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
     (Ring : Ring_Location; Slot : Natural) return Received_Frame
   is
      At_Offset : constant Natural := Slot * Descriptor_Bytes;
      Status    : constant U8 := Get_8 (Ring.Host, At_Offset + 12);
   begin
      return
        (Arrived  => (Status and Descriptor_Done) /= 0,
         Length   => Natural (Get_16 (Ring.Host, At_Offset + 8)),
         Complete => (Status and Descriptor_End_Of_Packet) /= 0,
         Errors   => Get_8 (Ring.Host, At_Offset + 13));
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
      Buffer : U64)
   is
      At_Offset : constant Natural := Slot * Descriptor_Bytes;
      Blank : Byte_Array (0 .. Descriptor_Bytes - 1) with Import,
        Address => Ring.Host + SSE.Storage_Offset (At_Offset);
   begin
      Blank := (others => 0);
      Put_64 (Ring.Host, At_Offset, Buffer);
      Reg.Write_Release_32 (BAR, Receive_Tail_Register, U32 (Slot));
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

end Flyology_VFIO_QEMU.E1000E;
