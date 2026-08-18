--  Reads an Intel gigabit controller's identity back out of its registers.
--
--  This device contributes three things nothing else here has: several base
--  address registers on one device, a region the kernel decorates with a
--  capability chain, and more than one interrupt vector.
--
--  It also contributes the best corpus available in a virtual machine. Its
--  receive address registers hold a MAC address chosen on the command line
--  that started the guest, so a value picked outside this program is
--  recovered inside it through MMIO. A register window reading plausible
--  rubbish fails that; a self-consistency check would not.

with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Flyology_DMA;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Interrupts;
with Flyology_VFIO.Regions;
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.E1000E;
with Harness;
with Interfaces;

procedure E1000E_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package IRQ renames Flyology_VFIO.Interrupts;
   package NIC renames Flyology_VFIO_QEMU.E1000E;
   package Reg renames Flyology_VFIO.Registers;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_32;
   use type NIC.MAC_Address;

   --  What the machine was started with, read from the environment so that
   --  the harness and the test cannot disagree silently.
   function Expected_MAC return String is
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_DEVICE_VM_MAC")
      then Ada.Environment_Variables.Value ("FLYOLOGY_DEVICE_VM_MAC")
      else "52:54:00:12:34:56");
begin
   declare
      Where : constant String := Find (NIC.Vendor_ID, NIC.Device_ID);

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
        (U32 (Config.Vendor_ID (Device)), U32 (NIC.Vendor_ID),
         "configuration space reports Intel");
      Harness.Check_Equal
        (U32 (Config.Device_ID (Device)), U32 (NIC.Device_ID),
         "configuration space reports the expected controller");

      --  Several regions on one device, which is what this device is for.
      declare
         Implemented   : Natural := 0;
         Mappable      : Natural := 0;
         With_Caps     : Natural := 0;
         Not_Mappable  : Natural := 0;
      begin
         for Index in Device_Regions.Region_Index range 0 .. 5 loop
            exit when Natural (Index) >= Devices.Region_Count (Device);
            declare
               Details : constant Device_Regions.Region_Details :=
                 Device_Regions.Describe (Device, Index);
            begin
               if Details.Implemented and then Details.Size > 0 then
                  Implemented := Implemented + 1;
                  Harness.Note
                    ("region" & Device_Regions.Region_Index'Image (Index)
                     & ":" & DMA.Byte_Count'Image (Details.Size) & " bytes"
                     & (if Details.Mappable then ", mappable"
                        else ", not mappable")
                     & (if Details.Has_Capabilities
                        then ", with a capability chain" else ""));
                  if Details.Mappable then
                     Mappable := Mappable + 1;
                  else
                     Not_Mappable := Not_Mappable + 1;
                  end if;
                  if Details.Has_Capabilities then
                     With_Caps := With_Caps + 1;
                  end if;
               end if;
            end;
         end loop;

         Harness.Check
           (Implemented > 1,
            "this device implements more than one region:"
            & Natural'Image (Implemented) & ", where every other device"
            & " here has one");
         Harness.Check (Mappable > 0, "at least one region is mappable");

         if With_Caps > 0 then
            Harness.Check
              (With_Caps > 0,
               "the kernel offers a capability chain for"
               & Natural'Image (With_Caps) & " region(s), which is the"
               & " two-call query this crate reports but does not yet read");
         else
            Harness.Skip
              ("capability chains", "this kernel offered none for it");
         end if;
      end;

      --  Several interrupt vectors, which is the other thing nothing else
      --  here exercises.
      declare
         MSI_X : constant IRQ.Interrupt_Details :=
           IRQ.Describe (Device, IRQ.MSI_X);
         Pin : constant IRQ.Interrupt_Details :=
           IRQ.Describe (Device, IRQ.Legacy_Pin);
      begin
         if MSI_X.Implemented and then MSI_X.Count > 0 then
            Harness.Note
              ("MSI-X offers" & Natural'Image (MSI_X.Count) & " vector(s)");
            Harness.Check
              (MSI_X.Count > 1, "it offers more than one MSI-X vector");
            Harness.Check
              (MSI_X.Supports_Eventfd,
               "its MSI-X vectors deliver on an eventfd");
         else
            Harness.Skip ("MSI-X shape", "this device reports no MSI-X");
         end if;

         if Pin.Implemented and then Pin.Count > 0 then
            Harness.Check
              (Pin.Automasked,
               "its pin interrupt is automasked, as a shared line must be");
         end if;
      end;

      declare
         BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (BAR, Device, NIC.Register_BAR);
         Harness.Note
           ("mapped registers,"
            & DMA.Byte_Count'Image (Device_Regions.Length (BAR)) & " bytes");
         Harness.Check
           (Device_Regions.Length (BAR) >= 16#20000#,
            "the register window is the full one hundred and twenty-eight"
            & " kibibytes, not a truncated mapping");

         Config.Enable_Memory_Space (Device);

         --  The corpus: an address chosen outside this program.
         declare
            Wanted : constant NIC.MAC_Address := NIC.Value (Expected_MAC);
            Seen   : constant NIC.MAC_Address := NIC.Hardware_Address (BAR);
         begin
            Harness.Note ("expected  " & NIC.Image (Wanted));
            Harness.Note ("read back " & NIC.Image (Seen));
            Harness.Check
              (NIC.Hardware_Address_Valid (BAR),
               "the device marks its first receive address as valid");
            Harness.Check
              (Seen = Wanted,
               "the hardware address read out of the device is the one the"
               & " virtual machine was started with");
         end;

         --  Registers at widely separated offsets, so a window mapped at
         --  the wrong place or with the wrong length cannot pass by only
         --  ever being read near its start.
         declare
            Status : constant U32 := Reg.Read_32 (BAR, NIC.Status_Register);
            Control : constant U32 :=
              Reg.Read_32 (BAR, NIC.Control_Register);
            Extended : constant U32 :=
              Reg.Read_32 (BAR, NIC.Extended_Control_Register);
         begin
            Harness.Note
              ("control 0x" & Hex_32 (Control) & ", status 0x"
               & Hex_32 (Status) & ", extended 0x" & Hex_32 (Extended));
            Harness.Check
              (Status /= 16#FFFF_FFFF# and then Control /= 16#FFFF_FFFF#,
               "the control and status registers do not read as all ones,"
               & " which is what an absent device returns");
            Harness.Check
              (Reg.Read_32 (BAR, NIC.Status_Register) = Status,
               "reading the status register twice agrees");
         end;

         --  A reset the device completes itself, which is a register a
         --  driver wrote coming back changed by the hardware.
         declare
            Before : constant NIC.MAC_Address := NIC.Hardware_Address (BAR);
         begin
            NIC.Reset (BAR);
            Harness.Check
              ((Reg.Read_32 (BAR, NIC.Control_Register) and NIC.Control_Reset)
                 = 0,
               "the device cleared the reset bit itself");
            Harness.Check
              (NIC.Hardware_Address (BAR) = Before,
               "the hardware address survived the reset, as it comes from"
               & " the device rather than from anything written to it");
         end;
      end;
   end;

   Harness.Report ("e1000e_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every e1000e check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("e1000e_tests");
   when Error : others =>
      Harness.Note
        ("unexpected: " & Ada.Exceptions.Exception_Name (Error) & ": "
         & Ada.Exceptions.Exception_Message (Error));
      Harness.Check (False, "the e1000e sequence completed without raising");
      Harness.Report ("e1000e_tests");
      Ada.Command_Line.Set_Exit_Status (1);
end E1000E_Tests;
