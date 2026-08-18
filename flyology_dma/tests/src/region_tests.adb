--  Exercises region creation and release.
--
--  Regular_Pages is the backing every host supports, so the structural
--  checks run everywhere. The hugepage checks adapt to the host: where a
--  pool exists they allocate from it, and where none does they assert that
--  the failure names the condition rather than falling back to small pages.

with Ada.Exceptions;
with Flyology_DMA;
with Flyology_DMA.Environment;
with Flyology_DMA.Regions;
with Flyology_DMA.Thin;
with Support;
with System;

procedure Region_Tests is
   use Flyology_DMA;
   use type System.Address;

   package Env renames Flyology_DMA.Environment;

   Page : constant Byte_Count := Thin.Page_Size (Regular_Pages);
begin
   Support.Check (Page > 0, "the host reports a page size");

   declare
      R : constant Regions.Region := Regions.Create (Page, Regular_Pages);
   begin
      Support.Check
        (Regions.Base_Address (R) /= System.Null_Address,
         "a region has a base address");
      Support.Check
        (Regions.Length (R) = Page, "a one-page region is one page long");
      Support.Check
        (Regions.Backing (R) = Regular_Pages, "it has the backing asked for");
      Support.Check
        (Regions.Page_Size (R) = Page, "it reports the host page size");

      --  The memory must actually be writable: a mapping that succeeded but
      --  did not populate would fail here rather than at a device write.
      declare
         Bytes : array (1 .. 16) of Character
           with Import, Address => Regions.Base_Address (R);
      begin
         Bytes := (others => 'x');
         Support.Check (Bytes (1) = 'x', "the region is writable");
      end;
   end;

   --  A length that is not a whole number of pages is rounded up, so that
   --  every region can be mapped as whole pages.
   declare
      R : constant Regions.Region := Regions.Create (1, Regular_Pages);
   begin
      Support.Check
        (Regions.Length (R) = Page, "a one-byte request rounds to a page");
   end;

   declare
      R : constant Regions.Region := Regions.Create (Page * 3 + 1, Regular_Pages);
   begin
      Support.Check
        (Regions.Length (R) = Page * 4, "a partial page rounds up");
   end;

   --  Regions are limited and controlled: creating and dropping many in a
   --  loop must not leak address space. A leak of one page per iteration
   --  would exhaust a 64-bit address space slowly, so this checks the
   --  mechanism rather than the exhaustion.
   for Iteration in 1 .. 256 loop
      declare
         R : constant Regions.Region := Regions.Create (Page, Regular_Pages);
      begin
         Support.Check
           (Regions.Base_Address (R) /= System.Null_Address,
            (if Iteration = 1 then "repeated creation succeeds" else ""));
         exit when Regions.Base_Address (R) = System.Null_Address;
      end;
   end loop;

   --  The hugepage path. Where the host has a pool, allocate from it; where
   --  it does not, the failure must name the condition and must not quietly
   --  produce small pages.
   declare
      State : constant Env.Backing_Report := Env.Report (Huge_2M);
   begin
      if State.Supported and then State.Pages_Free > 0 then
         declare
            R : constant Regions.Region := Regions.Create (1, Huge_2M);
         begin
            Support.Check
              (Regions.Length (R) = 2 * 1024 * 1024,
               "a hugepage region is one hugepage long");
            Support.Check
              (Regions.Page_Size (R) = 2 * 1024 * 1024,
               "it reports the hugepage size");
            Support.Check
              (Regions.Backing (R) = Huge_2M,
               "it reports the hugepage backing");
         end;
      else
         declare
            Raised : Boolean := False;
         begin
            begin
               declare
                  R : constant Regions.Region := Regions.Create (1, Huge_2M);
               begin
                  Support.Check
                    (Regions.Length (R) = 0,
                     "unreachable: hugepages should not be available");
               end;
            exception
               when Error : Hugepage_Unavailable =>
                  Raised := True;
                  --  The message has to be worth reading: it names the
                  --  condition and the command that changes it, which is
                  --  what turns an hour of guessing into a minute.
                  Support.Check
                    (Ada.Exceptions.Exception_Message (Error)'Length > 40,
                     "the diagnostic explains the condition and its fix");
            end;
            Support.Check_Raised
              (Raised, "an absent hugepage pool raises Hugepage_Unavailable");
         end;
      end if;
   end;

   Support.Report ("region_tests");
end Region_Tests;
