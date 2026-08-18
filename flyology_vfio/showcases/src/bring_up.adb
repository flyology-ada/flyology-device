--  Walks a PCI device through the whole VFIO lifecycle and back out.
--
--  Usage: bring_up <pci-address>, for example bring_up 0000:00:02.0
--
--  This is the milestone the crate was written to reach: open a container,
--  attach the device's group, set the IOMMU, get a device descriptor, read
--  the identity out of configuration space, map a region, map host memory
--  into the IOMMU, and take all of it down cleanly.
--
--  It knows nothing about any particular device. It reads the identity
--  rather than expecting one, and maps whichever region the kernel says is
--  mappable rather than assuming BAR0. A program that drives a specific
--  device belongs in a crate of its own; flyology_vfio_qemu is the one that
--  does that for QEMU's virtual devices.
--
--  Nothing here binds or unbinds a driver. The device must already be bound
--  to vfio-pci, which is a decision for whoever owns the machine.

with Ada.Command_Line;
with Ada.Text_IO;
with Flyology_DMA;
with Flyology_DMA.Mappers;
with Flyology_DMA.Regions;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.DMA_Mapper;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Interrupts;
with Flyology_VFIO.Regions;

procedure Bring_Up is
   use Flyology_VFIO;

   package CL renames Ada.Command_Line;
   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package IO renames Ada.Text_IO;
   package IRQ renames Flyology_VFIO.Interrupts;

   use type DMA.Byte_Count;

   function Hex (Value : Config.U16) return String is
      Digits_16 : constant String := "0123456789abcdef";
      Result    : String (1 .. 4);
      Remaining : Config.U16 := Value;
      use type Config.U16;
   begin
      for Position in reverse Result'Range loop
         Result (Position) :=
           Digits_16 (Natural (Remaining mod 16) + 1);
         Remaining := Remaining / 16;
      end loop;
      return Result;
   end Hex;

   --  An IOVA window away from anything a host virtual address would
   --  occupy, so that a value printed below is obviously one or the other,
   --  and low enough that every IOMMU can translate it.
   --
   --  The second half of that matters and is easy to miss: an IOMMU
   --  advertises an input address size, and this repository's own tests
   --  first used an address above it. VFIO_IOMMU_MAP_DMA accepted the
   --  mapping, and the failure appeared only when a device tried to follow
   --  the address. A driver should read the IOMMU's advertised ranges
   --  rather than pick, which is a capability-chain query this crate does
   --  not yet make.
   Window_Base : constant DMA.IOVA_Address := 16#0000_0001_0000_0000#;
begin
   if CL.Argument_Count /= 1 then
      IO.Put_Line ("usage: bring_up <pci-address>, e.g. 0000:00:02.0");
      CL.Set_Exit_Status (2);
      return;
   end if;

   declare
      Address : constant String := CL.Argument (1);
      Number  : constant Natural := Groups.Group_Of (Address);

      --  Declaration order is teardown order reversed, and here that is the
      --  whole design: the DMA mapping is removed before the mapper, the
      --  mapper before the container, the BAR unmapped before the device
      --  descriptor closes, and the group detached before the container
      --  goes. Getting this wrong leaves a device able to write into memory
      --  the process no longer owns.
      Container : Container_FD;
      Group     : Group_FD;
      Device    : Device_FD;
   begin
      IO.Put_Line ("device            " & Address);
      IO.Put_Line ("iommu group      " & Natural'Image (Number));

      Containers.Open (Container);
      IO.Put_Line ("container         open");

      Groups.Open (Group, Number);
      IO.Put_Line ("group             open and viable");

      Groups.Attach (Group, Container);
      IO.Put_Line ("group             attached to container");

      --  Only now is this legal: the precondition on Set_IOMMU requires an
      --  attached group, because the kernel refuses otherwise and says
      --  nothing about why.
      Containers.Set_IOMMU (Container);
      IO.Put_Line ("iommu             type1 v2 set");
      IO.Put_Line ("iommu page sizes  "
                   & Flyology_DMA.IOVA_Address'Image
                       (Flyology_DMA.IOVA_Address
                          (Containers.Supported_Page_Sizes (Container))));

      Devices.Open (Device, Group, Container, Address);
      IO.Put_Line ("device            open,"
                   & Natural'Image (Devices.Region_Count (Device))
                   & " regions,"
                   & Natural'Image (Devices.IRQ_Count (Device))
                   & " interrupt indices");

      --  Identity comes from configuration space, which VFIO never maps.
      IO.Put_Line ("vendor:device     " & Hex (Config.Vendor_ID (Device))
                   & ":" & Hex (Config.Device_ID (Device)));

      IO.Put_Line ("regions:");
      for Index in Regions.Region_Index range 0 .. 8 loop
         exit when Natural (Index) >= Devices.Region_Count (Device);
         declare
            Details : constant Regions.Region_Details :=
              Regions.Describe (Device, Index);
         begin
            if Details.Implemented and then Details.Size > 0 then
               IO.Put_Line
                 ("  " & Regions.Region_Index'Image (Index) & ":"
                  & DMA.Byte_Count'Image (Details.Size) & " bytes"
                  & (if Details.Mappable then ", mappable" else "")
                  & (if Details.Readable then ", readable" else "")
                  & (if Details.Writable then ", writable" else "")
                  & (if Details.Has_Capabilities
                     then ", has capabilities" else ""));
            end if;
         end;
      end loop;

      IO.Put_Line ("interrupts:");
      for Index in IRQ.IRQ_Index range 0 .. 3 loop
         exit when Natural (Index) >= Devices.IRQ_Count (Device);
         declare
            Details : constant IRQ.Interrupt_Details :=
              IRQ.Describe (Device, Index);
         begin
            if Details.Implemented and then Details.Count > 0 then
               IO.Put_Line
                 ("  " & IRQ.IRQ_Index'Image (Index) & ":"
                  & Natural'Image (Details.Count) & " vector(s)"
                  & (if Details.Supports_Eventfd then ", eventfd" else ""));
            end if;
         end;
      end loop;

      --  Map the first region the kernel says can be mapped.
      declare
         Chosen : Regions.Region_Index := 0;
         Found  : Boolean := False;
         Bar    : Regions.Window;
      begin
         for Index in Regions.Region_Index range 0 .. 5 loop
            exit when Natural (Index) >= Devices.Region_Count (Device);
            declare
               Details : constant Regions.Region_Details :=
                 Regions.Describe (Device, Index);
            begin
               if Details.Implemented and then Details.Mappable
                 and then Details.Size > 0
               then
                  Chosen := Index;
                  Found := True;
                  exit;
               end if;
            end;
         end loop;

         if Found then
            Regions.Map (Bar, Device, Chosen);
            IO.Put_Line ("mapped region     "
                         & Regions.Region_Index'Image (Chosen) & ","
                         & DMA.Byte_Count'Image (Regions.Length (Bar))
                         & " bytes");
         else
            IO.Put_Line ("mapped region     none of the regions is mappable");
         end if;

         --  Bus mastering, which VFIO does not enable and without which no
         --  DMA will ever happen. Enabled here so that the state a driver
         --  would need is the state this program leaves behind while it
         --  checks the mapping.
         Config.Enable_Bus_Mastering (Device);
         IO.Put_Line ("bus mastering     "
                      & (if Config.Bus_Mastering_Enabled (Device)
                         then "enabled" else "NOT enabled"));

         --  Host memory the device could reach, mapped through the IOMMU.
         declare
            Backend : aliased DMA_Mapper.Container_Mapper;
            Area    : constant DMA.Regions.Region :=
              DMA.Regions.Create (2 * 1024 * 1024, DMA.Regular_Pages);
         begin
            DMA_Mapper.Bind (Backend, Container);

            declare
               Bound : constant DMA.Mappers.Mapping :=
                 DMA.Mappers.Map_Region
                   (Backend'Access, Area, Window_Base,
                    DMA.Mappers.Device_Reads_And_Writes);
            begin
               IO.Put_Line ("dma mapping      "
                            & DMA.Byte_Count'Image (DMA.Mappers.Length (Bound))
                            & " bytes at IOVA"
                            & DMA.IOVA_Address'Image
                                (DMA.Mappers.IOVA_Base (Bound)));
               IO.Put_Line ("  host address    "
                            & DMA.IOVA_Address'Image
                                (DMA.Mirrored (DMA.Mappers.Host_Base (Bound)))
                            & "  (a different number, deliberately)");
            end;

            IO.Put_Line ("dma mapping       removed");
            Config.Disable_Bus_Mastering (Device);
         end;
      end;

      IO.Put_Line ("teardown          region unmapped, device closed,"
                   & " group detached, container closed");
   end;

   IO.Put_Line ("bring-up completed");
end Bring_Up;
