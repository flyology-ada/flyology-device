with Flyology_VFIO.Registers;
with Interfaces.C;

package body Flyology_VFIO_QEMU.E1000E is

   package Reg renames Flyology_VFIO.Registers;

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
