--  Drives QEMU's educational device through everything the crates below
--  can do to it.
--
--  The order is deliberate: cheap proofs first, so that when something
--  further down fails there is already evidence about what still worked.
--  Identity before liveness, liveness before computation, computation
--  before DMA, and DMA before interrupts.
--
--  The DMA checks are the ones worth having. Everything else could pass
--  with an IOMMU that translated nothing, because reads and writes of a
--  mapped BAR never involve the device following an address. A transfer
--  does: the device is handed an I/O virtual address and dereferences it,
--  so a mapping this code got wrong shows up as a transfer that moves
--  nothing or faults, rather than as silence.

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
with Flyology_VFIO.Interrupts;
with Flyology_VFIO.Regions;
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.Edu;
with Harness;
with Interfaces;
with System.Storage_Elements;

procedure Edu_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package IRQ renames Flyology_VFIO.Interrupts;
   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type DMA.Byte_Count;
   use type DMA.IOVA_Address;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type SSE.Storage_Offset;

   --  Choosing this address took two attempts, and both failures are worth
   --  recording because neither reported itself.
   --
   --  2**46 was accepted by VFIO_IOMMU_MAP_DMA and then refused by the
   --  IOMMU, which advertises a 44-bit input address size. 2**32 fitted the
   --  IOMMU but not the device, which masks bus addresses to twenty-eight
   --  bits and issues the transfer against the truncated result rather than
   --  complaining. In both cases every call returned success and no bytes
   --  moved.
   --
   --  An IOVA has to satisfy three separate constraints — the IOMMU's input
   --  width, the device's DMA width, and the ranges the platform reserves —
   --  and nothing checks them for you.
   --  Sixty-four mebibytes: inside the device's twenty-eight bit DMA mask,
   --  inside every IOMMU's input address size, and clear of the window
   --  arm64 reserves for interrupt messages at 0x0800_0000.
   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  Two buffers inside one mapped region: the device copies out of the
   --  first into its own memory, and back out into the second. Using two
   --  rather than one is what makes the check meaningful — a transfer that
   --  did nothing at all would leave the source looking correct.
   Source_Offset      : constant DMA.Byte_Count := 0;
   Destination_Offset : constant DMA.Byte_Count := 8192;
   Payload_Length     : constant := 4096;

begin
   declare
      Where : constant String := Find (Edu.Vendor_ID, Edu.Device_ID);

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
        (U32 (Config.Vendor_ID (Device)), U32 (Edu.Vendor_ID),
         "configuration space reports the expected vendor");
      Harness.Check_Equal
        (U32 (Config.Device_ID (Device)), U32 (Edu.Device_ID),
         "configuration space reports the expected device");

      --  The BAR. Everything below reads and writes through this mapping.
      declare
         Details : constant Device_Regions.Region_Details :=
           Device_Regions.Describe (Device, Edu.Register_BAR);
         BAR : Device_Regions.Window;
      begin
         Harness.Check (Details.Implemented, "the register BAR exists");
         Harness.Check (Details.Mappable, "the register BAR is mappable");
         Harness.Check
           (Details.Size >= 4096, "the register BAR is at least a page");

         Device_Regions.Map (BAR, Device, Edu.Register_BAR);
         Harness.Check (Device_Regions.Is_Mapped (BAR), "the BAR is mapped");
         Harness.Note
           ("BAR length" & DMA.Byte_Count'Image
              (Device_Regions.Length (BAR)) & " bytes");

         ------------------------------------------------------------------
         --  Identity and liveness: does anything reach the device at all
         ------------------------------------------------------------------

         declare
            Identity : constant U32 := Edu.Identification (BAR);
         begin
            Harness.Note ("identification 0x" & Hex_32 (Identity));
            Harness.Check
              (Edu.Is_Edu_Identification (Identity),
               "the identification register identifies this device");
         end;

         --  The device answers a probe with its complement. Several probes,
         --  including the two that would look the same either way if the
         --  register were stuck, and one that would pass if the device
         --  simply echoed the write back.
         declare
            type Probe_List is array (Positive range <>) of U32;
            Probes : constant Probe_List :=
              [16#0000_0000#, 16#FFFF_FFFF#, 16#5555_5555#,
               16#AAAA_AAAA#, 16#DEAD_BEEF#, 16#0000_0001#];
         begin
            for Probe of Probes loop
               Harness.Check_Equal
                 (Edu.Liveness_Answer (BAR, Probe), not Probe,
                  "the liveness register inverts 0x" & Hex_32 (Probe));
            end loop;
         end;

         ------------------------------------------------------------------
         --  Computation: the device does something over time, and says so
         ------------------------------------------------------------------

         Harness.Check_Equal (Edu.Factorial (BAR, 0), 1, "0! is 1");
         Harness.Check_Equal (Edu.Factorial (BAR, 1), 1, "1! is 1");
         Harness.Check_Equal (Edu.Factorial (BAR, 5), 120, "5! is 120");
         Harness.Check_Equal
           (Edu.Factorial (BAR, 10), 3_628_800, "10! is 3628800");
         Harness.Check_Equal
           (Edu.Factorial (BAR, 12), 479_001_600, "12! is 479001600");

         --  The status register's computing bit must be clear once a
         --  factorial has been collected, or the poll loop above returned
         --  on something other than completion.
         Harness.Check
           ((Edu.Status (BAR) and Edu.Status_Computing) = 0,
            "the computing bit is clear after a factorial finishes");

         ------------------------------------------------------------------
         --  DMA: the part that proves the IOMMU mapping is real
         ------------------------------------------------------------------

         Config.Enable_Bus_Mastering (Device);
         Harness.Check
           (Config.Bus_Mastering_Enabled (Device),
            "bus mastering is enabled, without which no transfer can start");

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

               Host : constant System.Address :=
                 DMA.Regions.Base_Address (Area);

               --  Volatile because a device writes them behind the
               --  compiler's back. Without it, nothing tells the optimiser
               --  that memory it watched this program zero can change
               --  before it is read again, and it is entitled to reuse
               --  what it already knows.
               Source_Bytes : array (1 .. Payload_Length) of U8
                 with Import, Volatile,
                      Address => Host + SSE.Storage_Offset (Source_Offset);
               Destination_Bytes : array (1 .. Payload_Length) of U8
                 with Import, Volatile,
                      Address =>
                        Host + SSE.Storage_Offset (Destination_Offset);
            begin
               Harness.Note
                 ("mapped" & DMA.Byte_Count'Image (DMA.Mappers.Length (Bound))
                  & " bytes at IOVA" & DMA.IOVA_Address'Image
                    (DMA.Mappers.IOVA_Base (Bound)));

               --  A pattern that is not constant, so a transfer that copied
               --  the wrong region, or copied nothing over zeroed memory,
               --  cannot pass by accident.
               for Index in Source_Bytes'Range loop
                  Source_Bytes (Index) := U8 ((Index * 7 + 13) mod 256);
               end loop;
               Destination_Bytes := (others => 0);

               --  Out to the device's own buffer, then back into a
               --  different part of the same region.
               Edu.Transfer
                 (BAR,
                  Source      => Window_Base + Device_Address (Source_Offset),
                  Destination => Edu.Device_Buffer_Base,
                  Count       => Payload_Length,
                  Direction   => Edu.To_Device);

               Harness.Note
                 ("destination bytes 1..4 before any transfer:"
                  & U8'Image (Destination_Bytes (1))
                  & U8'Image (Destination_Bytes (2))
                  & U8'Image (Destination_Bytes (3))
                  & U8'Image (Destination_Bytes (4))
                  & ", source bytes 1..4:"
                  & U8'Image (Source_Bytes (1))
                  & U8'Image (Source_Bytes (2))
                  & U8'Image (Source_Bytes (3))
                  & U8'Image (Source_Bytes (4)));

               Harness.Note
                 ("after the outward transfer the device reports source"
                  & U64'Image (Reg.Read_64 (BAR, Edu.DMA_Source_Register))
                  & " destination"
                  & U64'Image
                      (Reg.Read_64 (BAR, Edu.DMA_Destination_Register))
                  & " count"
                  & U64'Image (Reg.Read_64 (BAR, Edu.DMA_Count_Register)));

               Edu.Transfer
                 (BAR,
                  Source      => Edu.Device_Buffer_Base,
                  Destination =>
                    Window_Base + Device_Address (Destination_Offset),
                  Count       => Payload_Length,
                  Direction   => Edu.From_Device);

               declare
                  Identical : Boolean := True;
                  First_Bad : Natural := 0;
               begin
                  for Index in Source_Bytes'Range loop
                     if Source_Bytes (Index) /= Destination_Bytes (Index) then
                        Identical := False;
                        if First_Bad = 0 then
                           First_Bad := Index;
                        end if;
                     end if;
                  end loop;

                  Harness.Note
                    ("after the round trip, destination bytes 1..4:"
                     & U8'Image (Destination_Bytes (1))
                     & U8'Image (Destination_Bytes (2))
                     & U8'Image (Destination_Bytes (3))
                     & U8'Image (Destination_Bytes (4)));

                  Harness.Check
                    (Identical,
                     "the device carried" & Integer'Image (Payload_Length)
                     & " bytes out through one IOVA and back through"
                     & " another"
                     & (if First_Bad = 0 then ""
                        else ", first difference at byte"
                             & Natural'Image (First_Bad)));
               end;

               --  A partial transfer, at a non-zero offset, so that a
               --  device using the region base regardless of the address it
               --  was given would be caught.
               Destination_Bytes := (others => 0);
               Edu.Transfer
                 (BAR,
                  Source      => Edu.Device_Buffer_Base,
                  Destination =>
                    Window_Base + Device_Address (Destination_Offset) + 64,
                  Count       => 256,
                  Direction   => Edu.From_Device);

               Harness.Check
                 (Destination_Bytes (1) = 0
                    and then Destination_Bytes (64) = 0,
                  "a transfer at an offset left the bytes before it alone");
               Harness.Check
                 (Destination_Bytes (65) = Source_Bytes (1)
                    and then Destination_Bytes (320) = Source_Bytes (256),
                  "a transfer at an offset landed where it was told to");
               Harness.Check
                 (Destination_Bytes (321) = 0,
                  "a transfer of 256 bytes moved exactly 256 bytes");

               ---------------------------------------------------------
               --  Interrupts
               ---------------------------------------------------------

               declare
                  Details : constant IRQ.Interrupt_Details :=
                    IRQ.Describe (Device, IRQ.Legacy_Pin);
               begin
                  if not Details.Implemented
                    or else Details.Count = 0
                    or else not Details.Supports_Eventfd
                  then
                     Harness.Skip
                       ("interrupt delivery",
                        "this device offers no eventfd-capable interrupt");
                  else
                     declare
                        Event : IRQ.Event;
                     begin
                        Harness.Note
                          ("interrupt index" & IRQ.IRQ_Index'Image
                             (IRQ.Legacy_Pin) & " has"
                           & Natural'Image (Details.Count) & " vector(s),"
                           & (if Details.Automasked
                              then " automasked" else " not automasked"));
                        IRQ.Open (Event);
                        IRQ.Enable
                          (Device, IRQ.Legacy_Pin, (0 => IRQ.Descriptor (Event)));

                        Harness.Check
                          (IRQ.Take (Event) = 0,
                           "nothing is pending before anything is raised");

                        --  The device raises whatever is asked of it, which
                        --  is a cheap way to check delivery without waiting
                        --  for something else to happen first.
                        Edu.Raise_Interrupt (BAR, 1);

                        declare
                           Count  : Interfaces.Unsigned_64 := 0;
                           Polls  : Natural := 0;
                        begin
                           while Count = 0 and then Polls < 1_000_000 loop
                              Count := IRQ.Take (Event);
                              Polls := Polls + 1;
                           end loop;
                           Harness.Check
                             (Count > 0,
                              "the raised interrupt reached the eventfd");
                        end;

                        Edu.Acknowledge_Interrupt (BAR, 1);
                        Harness.Check
                          ((Edu.Interrupt_Status (BAR) and 1) = 0,
                           "acknowledging cleared the interrupt");

                        --  The device is quiet again, so the line can be
                        --  re-armed. Without this the next interrupt never
                        --  arrives: VFIO masks an automasked index on
                        --  delivery and leaves it masked.
                        if Details.Automasked then
                           IRQ.Unmask (Device, IRQ.Legacy_Pin);
                        end if;

                        --  And the one that matters for a driver: an
                        --  interrupt raised by the device itself at the end
                        --  of a transfer it was asked to announce.
                        Destination_Bytes := (others => 0);
                        Edu.Transfer
                          (BAR,
                           Source      => Edu.Device_Buffer_Base,
                           Destination =>
                             Window_Base + Device_Address (Destination_Offset),
                           Count       => Payload_Length,
                           Direction   => Edu.From_Device,
                           Announce    => True);

                        declare
                           Count : Interfaces.Unsigned_64 := 0;
                           Polls : Natural := 0;
                        begin
                           while Count = 0 and then Polls < 1_000_000 loop
                              Count := IRQ.Take (Event);
                              Polls := Polls + 1;
                           end loop;
                           Harness.Check
                             (Count > 0,
                              "the device announced the end of a transfer");
                        end;

                        Harness.Check
                          (Destination_Bytes (1) = Source_Bytes (1),
                           "the announced transfer moved the bytes too");

                        Edu.Acknowledge_Interrupt (BAR, Edu.DMA_Interrupt);
                        if Details.Automasked then
                           IRQ.Unmask (Device, IRQ.Legacy_Pin);
                        end if;
                        IRQ.Disable (Device, IRQ.Legacy_Pin);
                     end;
                  end if;
               end;
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   Harness.Report ("edu_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every edu check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("edu_tests");
end Edu_Tests;
