--  Brings an NVMe controller up and makes it answer a question.
--
--  The controller is disabled, its admin queues are pointed at memory the
--  IOMMU has been programmed for, and it is enabled again. It then reaches
--  that memory four times by DMA: reading the submission queue, writing the
--  completion queue, and writing four kibibytes of Identify data. Nothing
--  else in this repository asks a device to follow addresses it was given
--  through three separate registers.
--
--  The check that carries the most weight is the serial number. It is set
--  on the command line that starts the virtual machine, and it arrives here
--  only if every one of those addresses was right. A value chosen outside
--  the program and recovered inside it cannot be produced by a mistake that
--  happens to be self-consistent.

with Ada.Command_Line;
with Ada.Environment_Variables;
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
with Flyology_VFIO_QEMU.NVMe;
with Harness;
with Interfaces;
with System.Storage_Elements;

procedure NVMe_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package Controller renames Flyology_VFIO_QEMU.NVMe;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package IRQ renames Flyology_VFIO.Interrupts;
   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type SSE.Storage_Offset;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  Each structure gets a page of its own, because the controller is
   --  given page-aligned addresses and a queue that straddled a page would
   --  need a second pointer.
   Submission_Offset : constant DMA.Byte_Count := 0;
   Completion_Offset : constant DMA.Byte_Count := 4096;
   Identify_Offset   : constant DMA.Byte_Count := 8192;

   --  Sixteen entries is more than one command needs and small enough to
   --  fit a page either way.
   Queue_Entries : constant Positive := 16;

   --  What the machine was started with. Read from the environment so that
   --  the harness and the test cannot disagree about it silently.
   function Expected_Serial return String is
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_DEVICE_VM_NVME_SERIAL")
      then Ada.Environment_Variables.Value ("FLYOLOGY_DEVICE_VM_NVME_SERIAL")
      else "flyology0001");
begin
   declare
      Where : constant String := Find (Controller.Vendor_ID,
                                       Controller.Device_ID);

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
        (U32 (Config.Vendor_ID (Device)), U32 (Controller.Vendor_ID),
         "configuration space reports the expected vendor");
      Harness.Check_Equal
        (U32 (Config.Device_ID (Device)), U32 (Controller.Device_ID),
         "configuration space reports the expected device");

      --  Region and interrupt shape. This device is the first here with
      --  more than one of either.
      declare
         Mappable : Natural := 0;
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
                     & (if Details.Mappable then ", mappable" else "")
                     & (if Details.Has_Capabilities
                        then ", with a capability chain" else ""));
                  if Details.Mappable then
                     Mappable := Mappable + 1;
                  end if;
               end if;
            end;
         end loop;
         Harness.Check (Mappable > 0, "at least one region is mappable");
      end;

      declare
         MSI_X : constant IRQ.Interrupt_Details :=
           IRQ.Describe (Device, IRQ.MSI_X);
      begin
         if MSI_X.Implemented and then MSI_X.Count > 0 then
            Harness.Note
              ("MSI-X offers" & Natural'Image (MSI_X.Count) & " vector(s)");
            Harness.Check
              (MSI_X.Count > 1,
               "this device offers more than one interrupt vector, which"
               & " nothing else here does");
            Harness.Check
              (MSI_X.Supports_Eventfd,
               "its vectors can be delivered on an eventfd");
            Harness.Check
              (not MSI_X.Automasked,
               "MSI-X is not automasked, unlike a shared pin interrupt");
         else
            Harness.Skip ("MSI-X shape", "this controller reports no MSI-X");
         end if;
      end;

      declare
         BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (BAR, Device, Controller.Register_BAR);

         declare
            Capabilities : constant U64 :=
              Reg.Read_64 (BAR, Controller.Capabilities_Register);
            Version : constant U32 :=
              Reg.Read_32 (BAR, Controller.Version_Register);
            Stride : constant Positive :=
              Controller.Doorbell_Stride (Capabilities);
         begin
            Harness.Note
              ("version" & Natural'Image (Controller.Major_Version (Version))
               & "." & Natural'Image (Controller.Minor_Version (Version))
               & ", up to"
               & Positive'Image
                   (Controller.Maximum_Queue_Entries (Capabilities))
               & " queue entries, doorbell stride"
               & Positive'Image (Stride) & " bytes, minimum page"
               & Positive'Image (Controller.Minimum_Page_Size (Capabilities))
               & " bytes");

            --  A sixty-four bit register read as one access. A controller
            --  whose capabilities read as zero is one whose BAR is not
            --  really mapped.
            Harness.Check
              (Capabilities /= 0,
               "the capabilities register is not empty");
            Harness.Check
              (Controller.Major_Version (Version) >= 1,
               "the controller claims at least version one");
            Harness.Check
              (Controller.Maximum_Queue_Entries (Capabilities)
                 >= Queue_Entries,
               "it supports at least the queue size this test asks for");
            Harness.Check
              (Controller.Minimum_Page_Size (Capabilities) <= 4096,
               "it supports pages no larger than the ones being used");

            Config.Enable_Bus_Mastering (Device);
            Harness.Check
              (Config.Bus_Mastering_Enabled (Device),
               "bus mastering is enabled, without which the controller"
               & " cannot read its own queues");

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
                  --  Held for its lifetime, not for its value: the mapping
                  --  exists as long as this block does, and goes away with
                  --  it before the container closes.
                  pragma Unreferenced (Bound);

                  Host : constant System.Address :=
                    DMA.Regions.Base_Address (Area);

                  Submission : constant Controller.Queue_Location :=
                    (Host    => Host + SSE.Storage_Offset (Submission_Offset),
                     Device  => U64 (Window_Base) + U64 (Submission_Offset),
                     Entries => Queue_Entries);
                  Completion : constant Controller.Queue_Location :=
                    (Host    => Host + SSE.Storage_Offset (Completion_Offset),
                     Device  => U64 (Window_Base) + U64 (Completion_Offset),
                     Entries => Queue_Entries);

                  Identify_Host : constant System.Address :=
                    Host + SSE.Storage_Offset (Identify_Offset);
                  Identify_Device : constant U64 :=
                    U64 (Window_Base) + U64 (Identify_Offset);

                  --  Volatile: the controller writes these by DMA.
                  Queue_Bytes : array (1 .. 8192) of U8
                    with Import, Volatile, Address => Host;
                  Identify_Bytes : array (1 .. Controller.Identify_Bytes)
                    of U8 with Import, Volatile, Address => Identify_Host;
               begin
                  --  Queues must start empty, or a stale phase bit from a
                  --  previous run looks like a completion that never came.
                  Queue_Bytes := (others => 0);
                  Identify_Bytes := (others => 0);

                  Controller.Disable (BAR);
                  Harness.Check
                    (not Controller.Is_Ready (BAR),
                     "the controller reports itself not ready once disabled");

                  Controller.Enable (BAR, Submission, Completion);
                  Harness.Check
                    (Controller.Is_Ready (BAR),
                     "the controller became ready, which it can only do by"
                     & " reading the admin queues it was pointed at through"
                     & " the IOMMU");

                  Controller.Write_Identify_Command
                    (Submission, Slot => 0, Identifier => 16#ABCD#,
                     Result_Address => Identify_Device);

                  Controller.Ring_Submission_Doorbell
                    (BAR, Stride, Queue => 0, Tail => 1);

                  declare
                     Answer : constant Controller.Completion :=
                       Controller.Await_Completion
                         (Completion, Slot => 0, Expected_Phase => True);
                  begin
                     Harness.Check_Equal
                       (U32 (Answer.Identifier), 16#ABCD#,
                        "the completion carries the identifier the command"
                        & " was given");
                     Harness.Check_Equal
                       (U32 (Answer.Status), 0,
                        "the controller reported success");

                     Controller.Ring_Completion_Doorbell
                       (BAR, Stride, Queue => 0, Head => 1);
                  end;

                  --  And the payload. Four kibibytes the controller wrote
                  --  into memory it reached through an address this program
                  --  chose and the IOMMU translated.
                  declare
                     Serial : constant String :=
                       Controller.Identified_Serial (Identify_Host);
                     Model  : constant String :=
                       Controller.Identified_Model (Identify_Host);
                     Vendor : constant U16 :=
                       Controller.Identified_Vendor (Identify_Host);
                  begin
                     Harness.Note ("identified vendor 0x" & Hex_16 (Vendor));
                     Harness.Note ("identified model  " & Model);
                     Harness.Note ("identified serial " & Serial);

                     Harness.Check_Equal
                       (U32 (Vendor), U32 (Controller.Vendor_ID),
                        "the Identify data names the same vendor as"
                        & " configuration space");
                     Harness.Check
                       (Model'Length > 0,
                        "the model name is not empty");
                     Harness.Check
                       (Serial = Expected_Serial,
                        "the serial number is the one the virtual machine"
                        & " was started with: expected """
                        & Expected_Serial & """, and the controller"
                        & " delivered """ & Serial & """ by DMA");

                     --  A structure that is entirely one byte would satisfy
                     --  a string comparison by accident if the padding
                     --  happened to match, so check it is not.
                     declare
                        Distinct : Natural := 0;
                        Seen     : array (U8) of Boolean := (others => False);
                     begin
                        for Byte of Identify_Bytes loop
                           if not Seen (Byte) then
                              Seen (Byte) := True;
                              Distinct := Distinct + 1;
                           end if;
                        end loop;
                        Harness.Check
                          (Distinct > 4,
                           "the delivered structure holds"
                           & Natural'Image (Distinct) & " distinct byte"
                           & " values, so it is real data rather than a"
                           & " fill pattern");
                     end;
                  end;

                  Controller.Disable (BAR);
                  Harness.Check
                    (not Controller.Is_Ready (BAR),
                     "the controller stops again when disabled");
               end;

               Config.Disable_Bus_Mastering (Device);
            end;
         end;
      end;
   end;

   Harness.Report ("nvme_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every NVMe check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("nvme_tests");
   when Error : others =>
      Harness.Note
        ("unexpected: " & Ada.Exceptions.Exception_Name (Error) & ": "
         & Ada.Exceptions.Exception_Message (Error));
      Harness.Check (False, "the NVMe sequence completed without raising");
      Harness.Report ("nvme_tests");
      Ada.Command_Line.Set_Exit_Status (1);
end NVMe_Tests;
