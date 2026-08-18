with System.Storage_Elements;

package body Flyology_DMA is

   -----------------------
   -- Is_Power_Of_Two --
   -----------------------

   function Is_Power_Of_Two (Value : Alignment) return Boolean is
      --  Value is at least 1 by the type's own range, so the classic
      --  Value and (Value - 1) test needs no zero case. It is written with
      --  division rather than bit operations because Alignment is a signed
      --  range type, and introducing a modular view here would put a
      --  conversion in front of every caller's precondition.
      Remaining : Alignment := Value;
   begin
      while Remaining > 1 loop
         if Remaining mod 2 /= 0 then
            return False;
         end if;
         Remaining := Remaining / 2;
      end loop;
      return True;
   end Is_Power_Of_Two;

   --------------
   -- Mirrored --
   --------------

   function Mirrored (Host : System.Address) return IOVA_Address is
     (IOVA_Address (System.Storage_Elements.To_Integer (Host)));

   --------------
   -- Align_Up --
   --------------

   function Align_Up (Value : Byte_Count; To : Alignment) return Byte_Count is
      Step : constant Byte_Count := Byte_Count (To);
   begin
      return Value + (Step - 1) - (Value + (Step - 1)) mod Step;
   end Align_Up;

end Flyology_DMA;
