--  Exercises the mapper interface and the lifetime of a mapping.
--
--  The property under test is the teardown order. A region whose memory is
--  released while its device-visible mapping still stands leaves a device
--  able to write into pages the process no longer owns, and nothing reports
--  it until something unrelated is corrupted. The Mapping type exists to
--  make that ordering automatic, so these checks are mostly about lifetime.

with Flyology_DMA;
with Flyology_DMA.Mappers;
with Flyology_DMA.Regions;
with Flyology_DMA.Thin;
with Support;
with System;

procedure Mapper_Tests is
   use Flyology_DMA;
   package M renames Flyology_DMA.Mappers;
   use type M.Device_Access;
   use type System.Address;

   Page : constant Byte_Count := Thin.Page_Size (Regular_Pages);

   Backend : aliased M.Identity_Mapper;
begin
   Support.Check
     (M.Live_Mappings (Backend) = 0, "a fresh mapper has no live mappings");

   declare
      R : constant Regions.Region :=
        Regions.Create (Page * 4, Regular_Pages);
   begin
      declare
         Bound : constant M.Mapping :=
           M.Map_Region (Backend'Access, R, 16#4000_0000#, M.Device_Writes);
      begin
         Support.Check (M.Is_Live (Bound), "the mapping is live");
         Support.Check
           (M.Live_Mappings (Backend) = 1, "the mapper counts it");
         Support.Check
           (M.IOVA_Base (Bound) = 16#4000_0000#,
            "it carries the IOVA it was given");
         Support.Check
           (M.Host_Base (Bound) = Regions.Base_Address (R),
            "it carries the region's host address");
         Support.Check
           (M.Length (Bound) = Regions.Length (R),
            "it covers the whole region");
         Support.Check
           (M.Recorded_Direction (Backend, 16#4000_0000#) = M.Device_Writes,
            "the direction reached the mapper");
      end;

      Support.Check
        (M.Live_Mappings (Backend) = 0,
         "leaving the scope removed the mapping");
   end;

   --  Releasing explicitly and then finalizing must not unmap twice.
   declare
      R : constant Regions.Region :=
        Regions.Create (Page, Regular_Pages);
      Bound : M.Mapping := M.Map_Region (Backend'Access, R, 16#5000_0000#);
   begin
      M.Release (Bound);
      Support.Check (not M.Is_Live (Bound), "an explicit release takes");
      Support.Check
        (M.Live_Mappings (Backend) = 0, "the mapper's count came back down");
      M.Release (Bound);
      Support.Check
        (M.Live_Mappings (Backend) = 0, "releasing twice does nothing");
   end;

   --  Several mappings at once, each removed independently.
   declare
      R1 : constant Regions.Region :=
        Regions.Create (Page, Regular_Pages);
      R2 : constant Regions.Region :=
        Regions.Create (Page, Regular_Pages);
      M1 : M.Mapping := M.Map_Region (Backend'Access, R1, 16#6000_0000#);
      --  Never released explicitly: leaving the scope must remove it, which
      --  is the property under test.
      M2 : constant M.Mapping :=
        M.Map_Region (Backend'Access, R2, 16#7000_0000#);
      pragma Unreferenced (M2);
   begin
      Support.Check (M.Live_Mappings (Backend) = 2, "two mappings are live");
      M.Release (M1);
      Support.Check
        (M.Live_Mappings (Backend) = 1, "releasing one leaves the other");
      Support.Check
        (M.Recorded_Direction (Backend, 16#7000_0000#)
           = M.Device_Reads_And_Writes,
         "the surviving mapping is the one not released");
   end;
   Support.Check (M.Live_Mappings (Backend) = 0, "both are gone");

   --  Unmapping with a length that does not match the mapping is refused.
   --  VFIO cannot split a mapping, so an interface that appeared to allow
   --  it would work here and silently not there.
   declare
      Raised : Boolean := False;
   begin
      M.Map (Backend, System.Null_Address, Page, 16#8000_0000#,
             M.Device_Reads);
      begin
         M.Unmap (Backend, 16#8000_0000#, Page * 2);
      exception
         when Mapping_Error =>
            Raised := True;
      end;
      Support.Check_Raised (Raised, "a mismatched unmap is refused");
      M.Unmap (Backend, 16#8000_0000#, Page);
   end;

   --  Unmapping something never mapped is refused rather than ignored.
   declare
      Raised : Boolean := False;
   begin
      M.Unmap (Backend, 16#9999_0000#, Page);
   exception
      when Mapping_Error =>
         Raised := True;
         Support.Check_Raised (Raised, "an unknown unmap is refused");
   end;

   Support.Report ("mapper_tests");
end Mapper_Tests;
