with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C;
with System;

package body Runtime_Harness is

   use type Interfaces.C.long;

   Checks   : Natural := 0;
   Failures : Natural := 0;

   -----------
   -- Check --
   -----------

   procedure Check (Condition : Boolean; Label : String) is
   begin
      Checks := Checks + 1;
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("  FAIL  " & Label);
      end if;
   end Check;

   ----------
   -- Note --
   ----------

   procedure Note (Text : String) is
   begin
      Ada.Text_IO.Put_Line ("  ..    " & Text);
   end Note;

   ------------
   -- Signal --
   ------------

   procedure Signal (Descriptor : Integer) is
      function C_Write
        (FD : Interfaces.C.int; Buffer : System.Address;
         Count : Interfaces.C.size_t) return Interfaces.C.long
        with Import, Convention => C, External_Name => "write";

      --  An eventfd counts, so writing one adds one to its count and makes
      --  it readable — which is precisely what the kernel does on a device
      --  interrupt.
      One : aliased Interfaces.Unsigned_64 := 1;
   begin
      if C_Write (Interfaces.C.int (Descriptor), One'Address, 8) /= 8 then
         Ada.Text_IO.Put_Line ("  ..    could not signal the descriptor");
      end if;
   end Signal;

   ------------
   -- Report --
   ------------

   procedure Report (Program : String) is
   begin
      Ada.Text_IO.Put_Line ("  checks   " & Checks'Image);
      Ada.Text_IO.Put_Line ("  failures " & Failures'Image);
      if Failures = 0 then
         Ada.Text_IO.Put_Line ("PASS " & Program);
      else
         Ada.Text_IO.Put_Line ("FAIL " & Program);
         Ada.Command_Line.Set_Exit_Status (1);
      end if;
   end Report;

end Runtime_Harness;
