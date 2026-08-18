--  Exercises the root package's scalar arithmetic.
--
--  Align_Up is the one piece of arithmetic every other unit depends on:
--  region lengths, pool strides, and IOVA alignment all round through it, so
--  an error here would land somewhere else entirely.

with Flyology_DMA;
with Support;
with System.Storage_Elements;

procedure Scalar_Tests is
   use Flyology_DMA;

   Failed : Boolean;
begin
   Support.Check (Is_Power_Of_Two (1), "1 is a power of two");
   Support.Check (Is_Power_Of_Two (2), "2 is a power of two");
   Support.Check (Is_Power_Of_Two (4096), "4096 is a power of two");
   Support.Check
     (Is_Power_Of_Two (2 ** 40), "2**40 is a power of two");
   Support.Check (not Is_Power_Of_Two (3), "3 is not a power of two");
   Support.Check (not Is_Power_Of_Two (6), "6 is not a power of two");
   Support.Check
     (not Is_Power_Of_Two (4097), "4097 is not a power of two");

   Support.Check (Align_Up (0, 4096) = 0, "zero is already aligned");
   Support.Check (Align_Up (1, 4096) = 4096, "one rounds to a whole page");
   Support.Check
     (Align_Up (4096, 4096) = 4096, "an aligned value does not move");
   Support.Check
     (Align_Up (4097, 4096) = 8192, "one past a page rounds to two");
   Support.Check (Align_Up (100, 1) = 100, "alignment of one is identity");
   Support.Check
     (Align_Up (2 * 1024 * 1024 + 1, 2 * 1024 * 1024) = 4 * 1024 * 1024,
      "hugepage rounding");

   --  Mirrored is the only bridge between the two address worlds, so it is
   --  worth checking that it is a bit-pattern view and not a conversion
   --  that could round or truncate.
   declare
      Sample : constant System.Address :=
        System.Storage_Elements.To_Address (16#DEAD_BEEF_0000#);
   begin
      Support.Check
        (Mirrored (Sample) = 16#DEAD_BEEF_0000#,
         "Mirrored preserves the bit pattern");
   end;

   --  Preconditions are contracts, not suggestions: a non-power-of-two
   --  alignment must be refused rather than silently producing a value that
   --  is aligned to nothing.
   Failed := False;
   begin
      declare
         Ignored : constant Byte_Count := Align_Up (10, 3);
      begin
         Support.Check (Ignored > 0, "unreachable: 3 is not a power of two");
      end;
   exception
      when others =>
         Failed := True;
   end;
   Support.Check_Raised (Failed, "Align_Up refuses a non-power-of-two");

   Support.Report ("scalar_tests");
end Scalar_Tests;
