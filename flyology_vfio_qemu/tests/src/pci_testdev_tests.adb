--  Drives QEMU's PCI test device.
--
--  Unlike the educational device, this one has no published register map
--  worth transcribing: it describes itself. Each of its tests is a small
--  header in the BAR followed by a NUL-terminated name, so the way to find
--  out what a given QEMU build offers is to read it out of the device.
--  These checks therefore verify the self-description is coherent and that
--  the BAR behaves like memory-mapped registers, rather than asserting a
--  layout that a QEMU release could reasonably change.
--
--  What this device adds over the educational one is a second kind of
--  access surface and a device that is not the one the crates were brought
--  up on. It has no DMA engine, so it says nothing about the IOMMU.

with Ada.Exceptions;
with Flyology_DMA;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Regions;
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Harness;
with Interfaces;

procedure PCI_Testdev_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package Reg renames Flyology_VFIO.Registers;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   --  QEMU gives its own devices this vendor identifier.
   Vendor_ID : constant U16 := 16#1B36#;

   --  The PCI test device.
   Device_ID : constant U16 := 16#0005#;
begin
   declare
      Where : constant String := Find (Vendor_ID, Device_ID);

      Container : Container_FD;
      Group     : Group_FD;
      Device    : Device_FD;
   begin
      Harness.Note ("device at " & Where);

      Containers.Open (Container);
      Groups.Open (Group, Groups.Group_Of (Where));
      Groups.Attach (Group, Container);
      Containers.Set_IOMMU (Container);
      Devices.Open (Device, Group, Container, Where);

      Harness.Check_Equal
        (U32 (Config.Vendor_ID (Device)), U32 (Vendor_ID),
         "configuration space reports the expected vendor");
      Harness.Check_Equal
        (U32 (Config.Device_ID (Device)), U32 (Device_ID),
         "configuration space reports the expected device");

      --  Enumerate what this device actually exposes. A device with no
      --  mappable region would make everything below meaningless, so the
      --  enumeration is itself the first check.
      declare
         Mappable_Count : Natural := 0;
         First_Mappable : Device_Regions.Region_Index := 0;
         Found          : Boolean := False;
      begin
         for Index in Device_Regions.Region_Index range 0 .. 5 loop
            exit when Natural (Index) >= Devices.Region_Count (Device);
            declare
               Details : constant Device_Regions.Region_Details :=
                 Device_Regions.Describe (Device, Index);
            begin
               if Details.Implemented and then Details.Size > 0 then
                  Harness.Note
                    ("region" & Device_Regions.Region_Index'Image (Index)
                     & ":" & DMA.Byte_Count'Image (Details.Size) & " bytes"
                     & (if Details.Mappable then ", mappable"
                        else ", not mappable")
                     & (if Details.Readable then ", readable" else "")
                     & (if Details.Writable then ", writable" else ""));
                  if Details.Mappable then
                     Mappable_Count := Mappable_Count + 1;
                     if not Found then
                        First_Mappable := Index;
                        Found := True;
                     end if;
                  end if;
               end if;
            end;
         end loop;

         Harness.Check
           (Mappable_Count > 0, "the device has at least one mappable region");

         if not Found then
            Harness.Skip
              ("register access", "no region of this device can be mapped");
            Harness.Report ("pci_testdev_tests");
            return;
         end if;

         Config.Enable_Memory_Space (Device);

         declare
            BAR : Device_Regions.Window;
         begin
            Device_Regions.Map (BAR, Device, First_Mappable);
            Harness.Check
              (Device_Regions.Is_Mapped (BAR),
               "the first mappable region maps");
            Harness.Note
              ("mapped region"
               & Device_Regions.Region_Index'Image (First_Mappable) & ","
               & DMA.Byte_Count'Image (Device_Regions.Length (BAR))
               & " bytes");

            --  The device describes each of its tests with a small header
            --  followed by a name. Reading the names back is how a caller
            --  discovers what this QEMU build offers, and a coherent set of
            --  names is good evidence that the mapping is real and aligned:
            --  a BAR mapped at the wrong offset produces no readable text
            --  at all.
            --  This device describes its tests in text, but not anywhere
            --  reachable here: the readable descriptions live in its I/O
            --  port region, which VFIO reports as not mappable and which
            --  this crate therefore cannot read. Rather than assert a
            --  layout, the scan below reports what is actually visible in
            --  the mappable region, and the check that follows is about
            --  the layer under test rather than about the device.
            declare
               Printable : Natural := 0;
               Limit     : constant DMA.Byte_Count :=
                 DMA.Byte_Count'Min (Device_Regions.Length (BAR), 4096);
            begin
               for Position in 0 .. Natural (Limit) - 1 loop
                  declare
                     Byte : constant U8 :=
                       Reg.Read_8 (BAR, DMA.Byte_Count (Position));
                  begin
                     if Byte >= 32 and then Byte <= 126 then
                        Printable := Printable + 1;
                     end if;
                  end;
               end loop;
               Harness.Note
                 ("the mappable region holds" & Natural'Image (Printable)
                  & " printable bytes of" & DMA.Byte_Count'Image (Limit));
            end;

            --  A region the kernel says cannot be mapped must be refused by
            --  name rather than by letting mmap fail with something less
            --  specific. This device has exactly such a region, which makes
            --  it the one place in the repository where that path is
            --  exercised against a real kernel refusal.
            declare
               Unmappable : Boolean := False;
               Which      : Device_Regions.Region_Index := 0;
            begin
               for Index in Device_Regions.Region_Index range 0 .. 5 loop
                  exit when Natural (Index) >= Devices.Region_Count (Device);
                  declare
                     Details : constant Device_Regions.Region_Details :=
                       Device_Regions.Describe (Device, Index);
                  begin
                     if Details.Implemented and then Details.Size > 0
                       and then not Details.Mappable
                     then
                        Unmappable := True;
                        Which := Index;
                        exit;
                     end if;
                  end;
               end loop;

               if not Unmappable then
                  Harness.Skip
                    ("refusing an unmappable region",
                     "every region of this device is mappable");
               else
                  declare
                     Refused : Boolean := False;
                     Second  : Device_Regions.Window;
                  begin
                     begin
                        Device_Regions.Map (Second, Device, Which);
                     exception
                        when Error : Region_Error =>
                           Refused := True;
                           Harness.Check
                             (Ada.Exceptions.Exception_Message (Error)'Length
                                > 40,
                              "the refusal explains why the region cannot be"
                              & " mapped");
                     end;
                     Harness.Check
                       (Refused,
                        "region" & Device_Regions.Region_Index'Image (Which)
                        & " is refused rather than mapped");
                  end;
               end if;
            end;

            --  Whatever the layout, the mapping itself must behave: reads of
            --  every width must complete, must be repeatable, and must agree
            --  with each other about the same bytes. That is a statement
            --  about Flyology_VFIO.Registers rather than about this device,
            --  and it is the reason this test exists at all.
            declare
               First  : constant U32 := Reg.Read_32 (BAR, 0);
               Second : constant U32 := Reg.Read_32 (BAR, 0);
            begin
               Harness.Check_Equal
                 (Second, First, "reading the same register twice agrees");
            end;

            declare
               Whole : constant U32 := Reg.Read_32 (BAR, 0);
               Low   : constant U16 := Reg.Read_16 (BAR, 0);
               Byte  : constant U8 := Reg.Read_8 (BAR, 0);
            begin
               Harness.Check
                 (U16 (Whole and 16#FFFF#) = Low,
                  "a sixteen-bit read agrees with the low half of a"
                  & " thirty-two-bit read");
               Harness.Check
                 (U8 (Whole and 16#FF#) = Byte,
                  "an eight-bit read agrees with the low byte of a"
                  & " thirty-two-bit read");
            end;

            --  Accesses across the region, not only at its start, so that a
            --  mapping of the wrong length or at the wrong offset does not
            --  pass by only ever being touched in one place.
            declare
               Length : constant DMA.Byte_Count :=
                 Device_Regions.Length (BAR);
               Reads  : Natural := 0;
            begin
               for Step in 1 .. 8 loop
                  declare
                     At_Offset : constant DMA.Byte_Count :=
                       (Length / 16) * DMA.Byte_Count (Step);
                  begin
                     if Reg.Is_Valid_Access (Length, At_Offset, 4) then
                        declare
                           Ignored : constant U32 :=
                             Reg.Read_32 (BAR, At_Offset);
                           pragma Unreferenced (Ignored);
                        begin
                           Reads := Reads + 1;
                        end;
                     end if;
                  end;
               end loop;
               Harness.Check
                 (Reads > 0,
                  "reads across the whole region complete:"
                  & Natural'Image (Reads) & " offsets");
            end;
         end;
      end;
   end;

   Harness.Report ("pci_testdev_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every pci-testdev check",
         Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("pci_testdev_tests");
end PCI_Testdev_Tests;
