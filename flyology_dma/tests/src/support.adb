with Ada.Command_Line;
with Ada.Text_IO;

package body Support is

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

   -----------------
   -- Check_Equal --
   -----------------

   procedure Check_Equal (Actual, Expected : String; Label : String) is
   begin
      Checks := Checks + 1;
      if Actual /= Expected then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line
           ("  FAIL  " & Label & ": got """ & Actual & """, expected """
            & Expected & """");
      end if;
   end Check_Equal;

   -------------------
   -- Check_Raised --
   -------------------

   procedure Check_Raised (Raised : Boolean; Label : String) is
   begin
      Check (Raised, Label & " (expected an exception, none was raised)");
   end Check_Raised;

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

end Support;
