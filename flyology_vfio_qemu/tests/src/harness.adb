with Ada.Command_Line;
with Ada.Text_IO;

package body Harness is

   use type Flyology_VFIO_QEMU.U32;
   use type Flyology_VFIO_QEMU.U64;

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

   -----------------
   -- Check_Equal --
   -----------------

   procedure Check_Equal
     (Actual, Expected : Flyology_VFIO_QEMU.U32; Label : String) is
   begin
      Checks := Checks + 1;
      if Actual /= Expected then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line
           ("  FAIL  " & Label & ": got 0x"
            & Flyology_VFIO_QEMU.Hex_32 (Actual) & ", expected 0x"
            & Flyology_VFIO_QEMU.Hex_32 (Expected));
      end if;
   end Check_Equal;

   -----------------
   -- Check_Equal --
   -----------------

   procedure Check_Equal
     (Actual, Expected : Flyology_VFIO_QEMU.U64; Label : String) is
   begin
      Checks := Checks + 1;
      if Actual /= Expected then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line
           ("  FAIL  " & Label & ": got"
            & Flyology_VFIO_QEMU.U64'Image (Actual) & ", expected"
            & Flyology_VFIO_QEMU.U64'Image (Expected));
      end if;
   end Check_Equal;

   ----------
   -- Skip --
   ----------

   procedure Skip (Label : String; Because : String) is
   begin
      Skipped := Skipped + 1;
      Ada.Text_IO.Put_Line ("  SKIP  " & Label & ": " & Because);
   end Skip;

   ----------
   -- Note --
   ----------

   procedure Note (Text : String) is
   begin
      Ada.Text_IO.Put_Line ("  ..    " & Text);
   end Note;

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

end Harness;
