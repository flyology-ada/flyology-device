with Ada.Command_Line;
with Ada.Text_IO;

package body Support is

   Checks   : Natural := 0;
   Failures : Natural := 0;
   Skipped  : Natural := 0;

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

   -------------------
   -- Check_Raised --
   -------------------

   procedure Check_Raised (Raised : Boolean; Label : String) is
   begin
      Check (Raised, Label & " (expected an exception, none was raised)");
   end Check_Raised;

   ----------
   -- Skip --
   ----------

   procedure Skip (Label : String; Because : String) is
   begin
      Skipped := Skipped + 1;
      Ada.Text_IO.Put_Line ("  SKIP  " & Label & ": " & Because);
   end Skip;

   ------------
   -- Report --
   ------------

   procedure Report (Program : String) is
   begin
      Ada.Text_IO.Put_Line ("  checks   " & Checks'Image);
      Ada.Text_IO.Put_Line ("  failures " & Failures'Image);
      Ada.Text_IO.Put_Line ("  skipped  " & Skipped'Image);
      if Failures = 0 then
         Ada.Text_IO.Put_Line ("PASS " & Program);
      else
         Ada.Text_IO.Put_Line ("FAIL " & Program);
         Ada.Command_Line.Set_Exit_Status (1);
      end if;
   end Report;

end Support;
