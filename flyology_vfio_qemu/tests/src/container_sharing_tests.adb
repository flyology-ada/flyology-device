--  Two devices, two IOMMU groups, one container.
--
--  A container is the thing VFIO exists to provide: an address space that
--  devices are placed into, rather than a per-device translation. Every
--  other test in this repository uses one device, and one device cannot
--  demonstrate that property — with a single group attached, a container
--  and a device-private mapping behave identically.
--
--  So this test uses two, and the check that matters is the last one: a
--  region is mapped once, at one I/O virtual address, and the second device
--  reads what the first device wrote there. If that works, the two devices
--  are provably looking at the same address space. If a mapping were
--  somehow per-device, the second device's read would fault instead.
--
--  It also exercises the group bookkeeping that gates the lifecycle. The
--  count of attached groups has never been above one anywhere else, so
--  nothing has checked that it rises twice and falls back correctly.

with Ada.Exceptions;
with Flyology_DMA;
with Flyology_DMA.Mappers;
with Flyology_DMA.Regions;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.DMA_Mapper;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Regions;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.Edu;
with Harness;
with Interfaces;
with System.Storage_Elements;

procedure Container_Sharing_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package SSE renames System.Storage_Elements;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type SSE.Storage_Offset;

   --  Inside the devices' twenty-eight bit DMA mask and clear of the window
   --  arm64 reserves for interrupt messages.
   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  Three buffers in one region: what the first device is given, where it
   --  puts it back, and where the second device puts it after reading the
   --  first device's output through the same address space.
   First_Offset  : constant DMA.Byte_Count := 0;
   Second_Offset : constant DMA.Byte_Count := 8192;
   Third_Offset  : constant DMA.Byte_Count := 16384;
   Payload       : constant := 4096;
begin
   if Available (Edu.Vendor_ID, Edu.Device_ID) < 2 then
      Harness.Skip
        ("everything",
         "two of the same device bound to vfio-pci are needed, and"
         & Natural'Image (Available (Edu.Vendor_ID, Edu.Device_ID))
         & " are present. scripts/qemu/run.sh attaches two.");
      Harness.Report ("container_sharing_tests");
      return;
   end if;

   declare
      First_Where  : constant String := Find (Edu.Vendor_ID, Edu.Device_ID, 1);
      Second_Where : constant String := Find (Edu.Vendor_ID, Edu.Device_ID, 2);

      First_Group_Number  : constant Natural := Groups.Group_Of (First_Where);
      Second_Group_Number : constant Natural := Groups.Group_Of (Second_Where);

      Container    : Container_FD;
      First_Group  : Group_FD;
      Second_Group : Group_FD;
      First_Device : Device_FD;
      Second_Device : Device_FD;
   begin
      Harness.Note ("first device at " & First_Where & ", group"
                    & Natural'Image (First_Group_Number));
      Harness.Note ("second device at " & Second_Where & ", group"
                    & Natural'Image (Second_Group_Number));

      Harness.Check
        (First_Where /= Second_Where,
         "the two instances are different devices");
      Harness.Check
        (First_Group_Number /= Second_Group_Number,
         "they are in different IOMMU groups, which is what makes this"
         & " worth testing at all");

      Containers.Open (Container);
      Harness.Check
        (Containers.Attached_Groups (Container) = 0,
         "a fresh container has no groups");

      Groups.Open (First_Group, First_Group_Number);
      Groups.Attach (First_Group, Container);
      Harness.Check
        (Containers.Attached_Groups (Container) = 1,
         "attaching the first group counts one");

      Groups.Open (Second_Group, Second_Group_Number);
      Groups.Attach (Second_Group, Container);
      Harness.Check
        (Containers.Attached_Groups (Container) = 2,
         "attaching the second group counts two");
      Harness.Check
        (Groups.Is_Attached_To (First_Group, Container)
           and then Groups.Is_Attached_To (Second_Group, Container),
         "both groups report themselves attached to this container");

      --  One SET_IOMMU for both groups: the IOMMU belongs to the container,
      --  not to a group.
      Containers.Set_IOMMU (Container);
      Harness.Check
        (Containers.IOMMU_Is_Set (Container), "the IOMMU is set once");

      Devices.Open (First_Device, First_Group, Container, First_Where);
      Devices.Open (Second_Device, Second_Group, Container, Second_Where);
      Harness.Check
        (Devices.Is_Open (First_Device) and then Devices.Is_Open (Second_Device),
         "both devices open from their own groups");

      declare
         First_BAR  : Device_Regions.Window;
         Second_BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (First_BAR, First_Device, Edu.Register_BAR);
         Device_Regions.Map (Second_BAR, Second_Device, Edu.Register_BAR);

         Harness.Check
           (Edu.Is_Edu_Identification (Edu.Identification (First_BAR))
              and then Edu.Is_Edu_Identification
                         (Edu.Identification (Second_BAR)),
            "both mapped regions identify as the expected device");

         --  Two mappings of two different devices must be distinct windows.
         --  Mapping the second over the first would make everything below
         --  pass while testing one device twice.
         Harness.Check
           (Device_Regions.Base (First_BAR)
              /= Device_Regions.Base (Second_BAR),
            "the two BARs are mapped at different addresses");

         --  A probe answered by one device and not the other proves the two
         --  windows really do reach different hardware.
         declare
            First_Answer  : constant U32 :=
              Edu.Liveness_Answer (First_BAR, 16#1111_2222#);
            Second_Answer : constant U32 :=
              Edu.Liveness_Answer (Second_BAR, 16#3333_4444#);
         begin
            Harness.Check_Equal
              (First_Answer, not U32'(16#1111_2222#),
               "the first device answered its own probe");
            Harness.Check_Equal
              (Second_Answer, not U32'(16#3333_4444#),
               "the second device answered a different probe");
            Harness.Check_Equal
              (Edu.Liveness_Answer (First_BAR, 16#1111_2222#),
               not U32'(16#1111_2222#),
               "the first device still answers its own, so the second did"
               & " not overwrite it");
         end;

         Config.Enable_Bus_Mastering (First_Device);
         Config.Enable_Bus_Mastering (Second_Device);

         declare
            Backend : aliased DMA_Mapper.Container_Mapper;
            Area    : constant DMA.Regions.Region :=
              DMA.Regions.Create (2 * 1024 * 1024, DMA.Regular_Pages);
         begin
            DMA_Mapper.Bind (Backend, Container);

            declare
               --  One mapping. Not one per device: that is the point.
               Bound : constant DMA.Mappers.Mapping :=
                 DMA.Mappers.Map_Region
                   (Backend'Access, Area, Window_Base,
                    DMA.Mappers.Device_Reads_And_Writes);

               Host : constant System.Address :=
                 DMA.Regions.Base_Address (Area);

               First_Bytes : array (1 .. Payload) of U8
                 with Import, Volatile,
                      Address => Host + SSE.Storage_Offset (First_Offset);
               Second_Bytes : array (1 .. Payload) of U8
                 with Import, Volatile,
                      Address => Host + SSE.Storage_Offset (Second_Offset);
               Third_Bytes : array (1 .. Payload) of U8
                 with Import, Volatile,
                      Address => Host + SSE.Storage_Offset (Third_Offset);
            begin
               Harness.Note
                 ("one region of"
                  & DMA.Byte_Count'Image (DMA.Mappers.Length (Bound))
                  & " bytes mapped once, at IOVA"
                  & DMA.IOVA_Address'Image (DMA.Mappers.IOVA_Base (Bound)));

               for Index in First_Bytes'Range loop
                  First_Bytes (Index) := U8 ((Index * 11 + 5) mod 256);
               end loop;
               Second_Bytes := (others => 0);
               Third_Bytes := (others => 0);

               --  The first device carries the pattern through its own
               --  buffer and back out to the second offset.
               Edu.Transfer
                 (First_BAR,
                  Source      => U64 (Window_Base) + U64 (First_Offset),
                  Destination => Edu.Device_Buffer_Base,
                  Count       => Payload,
                  Direction   => Edu.To_Device);
               Edu.Transfer
                 (First_BAR,
                  Source      => Edu.Device_Buffer_Base,
                  Destination => U64 (Window_Base) + U64 (Second_Offset),
                  Count       => Payload,
                  Direction   => Edu.From_Device);

               Harness.Check
                 (Second_Bytes (1) = First_Bytes (1)
                    and then Second_Bytes (Payload) = First_Bytes (Payload),
                  "the first device round-tripped the pattern");

               --  And now the check this whole test exists for: the second
               --  device reads, through the same I/O virtual address, what
               --  the first device wrote there.
               Edu.Transfer
                 (Second_BAR,
                  Source      => U64 (Window_Base) + U64 (Second_Offset),
                  Destination => Edu.Device_Buffer_Base,
                  Count       => Payload,
                  Direction   => Edu.To_Device);
               Edu.Transfer
                 (Second_BAR,
                  Source      => Edu.Device_Buffer_Base,
                  Destination => U64 (Window_Base) + U64 (Third_Offset),
                  Count       => Payload,
                  Direction   => Edu.From_Device);

               declare
                  Identical : Boolean := True;
                  First_Bad : Natural := 0;
               begin
                  for Index in First_Bytes'Range loop
                     if Third_Bytes (Index) /= First_Bytes (Index) then
                        Identical := False;
                        if First_Bad = 0 then
                           First_Bad := Index;
                        end if;
                     end if;
                  end loop;
                  Harness.Check
                    (Identical,
                     "the second device read what the first wrote, through"
                     & " one mapping made once: a container is a single"
                     & " address space shared by every group in it"
                     & (if First_Bad = 0 then ""
                        else ", first difference at byte"
                             & Natural'Image (First_Bad)));
               end;
            end;

            Config.Disable_Bus_Mastering (First_Device);
            Config.Disable_Bus_Mastering (Second_Device);
         end;
      end;

      --  Detaching one group must leave the other attached. Nothing else
      --  checks that the count comes down by one rather than to zero.
      Devices.Close (Second_Device);
      Groups.Detach (Second_Group, Container);
      Harness.Check
        (Containers.Attached_Groups (Container) = 1,
         "detaching one group leaves the other attached");
      Harness.Check
        (not Groups.Is_Attached_To (Second_Group, Container),
         "the detached group no longer claims the container");
      Harness.Check
        (Groups.Is_Attached_To (First_Group, Container),
         "the group that was not detached still claims it");
   end;

   Harness.Report ("container_sharing_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("container_sharing_tests");
end Container_Sharing_Tests;
