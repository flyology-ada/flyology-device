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
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type SSE.Storage_Offset;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  Each structure gets a page of its own, because the controller is
   --  given page-aligned addresses and a queue that straddled a page would
   --  need a second pointer.
   Submission_Offset      : constant DMA.Byte_Count := 0;
   Completion_Offset      : constant DMA.Byte_Count := 4096;
   Identify_Offset        : constant DMA.Byte_Count := 8192;
   Namespace_Info_Offset  : constant DMA.Byte_Count := 12288;
   IO_Submission_Offset   : constant DMA.Byte_Count := 16384;
   IO_Completion_Offset   : constant DMA.Byte_Count := 20480;
   Write_Buffer_Offset    : constant DMA.Byte_Count := 24576;
   Read_Buffer_Offset     : constant DMA.Byte_Count := 28672;

   --  One I/O queue pair is enough to read and write. A real driver makes
   --  one per core; a harness making several would only be testing that it
   --  can count.
   IO_Queue : constant Positive := 1;

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

                  Namespace_Host : constant System.Address :=
                    Host + SSE.Storage_Offset (Namespace_Info_Offset);
                  Namespace_Info_Device : constant U64 :=
                    U64 (Window_Base) + U64 (Namespace_Info_Offset);

                  IO_Submission : constant Controller.Queue_Location :=
                    (Host    =>
                       Host + SSE.Storage_Offset (IO_Submission_Offset),
                     Device  =>
                       U64 (Window_Base) + U64 (IO_Submission_Offset),
                     Entries => Queue_Entries);
                  IO_Completion : constant Controller.Queue_Location :=
                    (Host    =>
                       Host + SSE.Storage_Offset (IO_Completion_Offset),
                     Device  =>
                       U64 (Window_Base) + U64 (IO_Completion_Offset),
                     Entries => Queue_Entries);

                  IO_Submission_Device : constant U64 := IO_Submission.Device;
                  IO_Completion_Device : constant U64 := IO_Completion.Device;

                  Write_Buffer_Device : constant U64 :=
                    U64 (Window_Base) + U64 (Write_Buffer_Offset);
                  Read_Buffer_Device : constant U64 :=
                    U64 (Window_Base) + U64 (Read_Buffer_Offset);

                  Write_Bytes : array (1 .. 4096) of U8
                    with Import, Volatile,
                         Address =>
                           Host + SSE.Storage_Offset (Write_Buffer_Offset);
                  Read_Bytes : array (1 .. 4096) of U8
                    with Import, Volatile,
                         Address =>
                           Host + SSE.Storage_Offset (Read_Buffer_Offset);

                  Block_Bytes : Positive := 512;
                  Block_Count : U64 := 0;

                  --  Volatile: the controller writes these by DMA.
                  --  Every queue and buffer, cleared in one go. A stale
                  --  phase bit left by a previous run looks exactly like a
                  --  completion that never arrived.
                  Queue_Bytes : array (1 .. 32768) of U8
                    with Import, Volatile, Address => Host;

               begin
                  --  Queues must start empty, or a stale phase bit from a
                  --  previous run looks like a completion that never came.
                  Queue_Bytes := (others => 0);

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

                  --  Admin commands go through one slot at a time. The
                  --  phase bit distinguishes a completion the controller
                  --  has just written from whatever was in the queue
                  --  before, and it flips each time the queue wraps.
                  declare
                     Admin_Slot  : Natural := 0;
                     Admin_Phase : Boolean := True;
                     Next_ID     : U16 := 16#1000#;

                     function Run_Admin return Controller.Completion;

                     -----------------
                     -- Run_Admin --
                     -----------------

                     --  Rings the doorbell for the command already written
                     --  into the current slot, waits for its completion,
                     --  and tells the controller the completion has been
                     --  consumed.
                     function Run_Admin return Controller.Completion is
                        Answer : Controller.Completion;
                     begin
                        Controller.Ring_Submission_Doorbell
                          (BAR, Stride, Queue => 0,
                           Tail => (Admin_Slot + 1) mod Queue_Entries);
                        Answer := Controller.Await_Completion
                          (Completion, Admin_Slot, Admin_Phase);
                        Controller.Ring_Completion_Doorbell
                          (BAR, Stride, Queue => 0,
                           Head => (Admin_Slot + 1) mod Queue_Entries);
                        Admin_Slot := (Admin_Slot + 1) mod Queue_Entries;
                        if Admin_Slot = 0 then
                           Admin_Phase := not Admin_Phase;
                        end if;
                        return Answer;
                     end Run_Admin;
                  begin
                     ------------------------------------------------------
                     --  Identify the controller
                     ------------------------------------------------------

                     Controller.Write_Identify_Command
                       (Submission, Admin_Slot, Next_ID, Identify_Device);
                     declare
                        Answer : constant Controller.Completion := Run_Admin;
                     begin
                        Harness.Check_Equal
                          (U32 (Answer.Identifier), U32 (Next_ID),
                           "the completion carries the identifier the"
                           & " command was given");
                        Harness.Check_Equal
                          (U32 (Answer.Status), 0,
                           "Identify Controller succeeded");
                     end;
                     Next_ID := Next_ID + 1;

                     declare
                        Serial : constant String :=
                          Controller.Identified_Serial (Identify_Host);
                        Model  : constant String :=
                          Controller.Identified_Model (Identify_Host);
                        Vendor : constant U16 :=
                          Controller.Identified_Vendor (Identify_Host);
                        Count  : constant U32 :=
                          Controller.Identified_Namespace_Count
                            (Identify_Host);
                     begin
                        Harness.Note ("identified vendor 0x" & Hex_16 (Vendor));
                        Harness.Note ("identified model  " & Model);
                        Harness.Note ("identified serial " & Serial);
                        Harness.Note
                          ("namespaces" & U32'Image (Count));

                        Harness.Check_Equal
                          (U32 (Vendor), U32 (Controller.Vendor_ID),
                           "the Identify data names the same vendor as"
                           & " configuration space");
                        Harness.Check
                          (Model'Length > 0, "the model name is not empty");
                        Harness.Check
                          (Serial = Expected_Serial,
                           "the serial number is the one the virtual machine"
                           & " was started with: expected """
                           & Expected_Serial & """, and the controller"
                           & " delivered """ & Serial & """ by DMA");
                        Harness.Check
                          (Count >= 1,
                           "the controller has at least one namespace");
                     end;

                     ------------------------------------------------------
                     --  Identify the namespace
                     ------------------------------------------------------

                     Controller.Write_Identify_Namespace_Command
                       (Submission, Admin_Slot, Next_ID, 1,
                        Namespace_Info_Device);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "Identify Namespace succeeded");
                     Next_ID := Next_ID + 1;

                     Block_Bytes :=
                       Controller.Namespace_Block_Bytes (Namespace_Host);
                     Block_Count :=
                       Controller.Namespace_Blocks (Namespace_Host);
                     Harness.Note
                       ("namespace 1 holds" & U64'Image (Block_Count)
                        & " blocks of" & Positive'Image (Block_Bytes)
                        & " bytes");
                     Harness.Check
                       (Block_Count > 0,
                        "the namespace reports a non-empty capacity");
                     Harness.Check
                       (Block_Bytes >= 512 and then Block_Bytes <= 4096,
                        "its block size is one a driver can work with");
                     Harness.Check
                       (U64 (Block_Bytes) * Block_Count >= 16#100_0000#,
                        "the namespace is at least the sixteen mebibytes the"
                        & " machine was given");

                     ------------------------------------------------------
                     --  Create an I/O queue pair
                     ------------------------------------------------------

                     --  The completion queue first. A submission queue
                     --  naming a completion queue that does not exist is
                     --  rejected, which is one of the few orderings NVMe
                     --  states outright.
                     Controller.Write_Create_Completion_Queue_Command
                       (Submission, Admin_Slot, Next_ID, IO_Queue,
                        Queue_Entries, IO_Completion_Device);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "creating the I/O completion queue succeeded");
                     Next_ID := Next_ID + 1;

                     Controller.Write_Create_Submission_Queue_Command
                       (Submission, Admin_Slot, Next_ID, IO_Queue, IO_Queue,
                        Queue_Entries, IO_Submission_Device);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "creating the I/O submission queue succeeded");
                     Next_ID := Next_ID + 1;

                     ------------------------------------------------------
                     --  Write blocks, read them back, compare
                     ------------------------------------------------------

                     declare
                        IO_Slot  : Natural := 0;
                        IO_Phase : Boolean := True;

                        function Run_IO return Controller.Completion;

                        function Run_IO return Controller.Completion is
                           Answer : Controller.Completion;
                        begin
                           Controller.Ring_Submission_Doorbell
                             (BAR, Stride, Queue => IO_Queue,
                              Tail => (IO_Slot + 1) mod Queue_Entries);
                           Answer := Controller.Await_Completion
                             (IO_Completion, IO_Slot, IO_Phase);
                           Controller.Ring_Completion_Doorbell
                             (BAR, Stride, Queue => IO_Queue,
                              Head => (IO_Slot + 1) mod Queue_Entries);
                           IO_Slot := (IO_Slot + 1) mod Queue_Entries;
                           if IO_Slot = 0 then
                              IO_Phase := not IO_Phase;
                           end if;
                           return Answer;
                        end Run_IO;

                        Blocks_Per_Buffer : constant Positive :=
                          Positive (4096 / Block_Bytes);
                     begin
                        --  A pattern with no repeating period shorter than
                        --  the buffer, so a read that returned the wrong
                        --  block, or a stale one, cannot match by accident.
                        for Index in Write_Bytes'Range loop
                           Write_Bytes (Index) :=
                             U8 ((Index * 31 + 17) mod 256);
                        end loop;
                        Read_Bytes := (others => 0);

                        Controller.Write_Block_Command
                          (IO_Submission, IO_Slot, Next_ID,
                           Controller.Opcode_Write, 1, 0,
                           Blocks_Per_Buffer, Write_Buffer_Device);
                        Harness.Check_Equal
                          (U32 (Run_IO.Status), 0,
                           "writing" & Positive'Image (Blocks_Per_Buffer)
                           & " block(s) at block zero succeeded");
                        Next_ID := Next_ID + 1;

                        Controller.Write_Block_Command
                          (IO_Submission, IO_Slot, Next_ID,
                           Controller.Opcode_Read, 1, 0,
                           Blocks_Per_Buffer, Read_Buffer_Device);
                        Harness.Check_Equal
                          (U32 (Run_IO.Status), 0, "reading them back"
                           & " succeeded");
                        Next_ID := Next_ID + 1;

                        declare
                           Identical : Boolean := True;
                           First_Bad : Natural := 0;
                        begin
                           for Index in Write_Bytes'Range loop
                              if Read_Bytes (Index) /= Write_Bytes (Index)
                              then
                                 Identical := False;
                                 if First_Bad = 0 then
                                    First_Bad := Index;
                                 end if;
                              end if;
                           end loop;
                           Harness.Check
                             (Identical,
                              "every byte written to the namespace came back"
                              & " unchanged"
                              & (if First_Bad = 0 then ""
                                 else ", first difference at byte"
                                      & Natural'Image (First_Bad)));
                        end;

                        --  A second write, at a different block, must not
                        --  disturb the first. A driver that ignored the
                        --  block number would pass everything above.
                        for Index in Write_Bytes'Range loop
                           Write_Bytes (Index) :=
                             U8 ((Index * 7 + 200) mod 256);
                        end loop;

                        Controller.Write_Block_Command
                          (IO_Submission, IO_Slot, Next_ID,
                           Controller.Opcode_Write, 1,
                           U64 (Blocks_Per_Buffer) * 4,
                           Blocks_Per_Buffer, Write_Buffer_Device);
                        Harness.Check_Equal
                          (U32 (Run_IO.Status), 0,
                           "writing at a later block succeeded");
                        Next_ID := Next_ID + 1;

                        Read_Bytes := (others => 0);
                        Controller.Write_Block_Command
                          (IO_Submission, IO_Slot, Next_ID,
                           Controller.Opcode_Read, 1,
                           U64 (Blocks_Per_Buffer) * 4,
                           Blocks_Per_Buffer, Read_Buffer_Device);
                        Harness.Check_Equal
                          (U32 (Run_IO.Status), 0,
                           "reading the later block back succeeded");
                        Next_ID := Next_ID + 1;

                        Harness.Check
                          (Read_Bytes (1) = Write_Bytes (1)
                             and then Read_Bytes (4096) = Write_Bytes (4096),
                           "the later block holds the second pattern");

                        Read_Bytes := (others => 0);
                        Controller.Write_Block_Command
                          (IO_Submission, IO_Slot, Next_ID,
                           Controller.Opcode_Read, 1, 0,
                           Blocks_Per_Buffer, Read_Buffer_Device);
                        Harness.Check_Equal
                          (U32 (Run_IO.Status), 0,
                           "reading block zero again succeeded");
                        Next_ID := Next_ID + 1;

                        Harness.Check
                          (Read_Bytes (1) = U8 ((1 * 31 + 17) mod 256)
                             and then Read_Bytes (4096)
                                      = U8 ((4096 * 31 + 17) mod 256),
                           "block zero still holds the first pattern, so"
                           & " the second write went where it was told");

                        --  And a command that must fail. A read past the
                        --  end of the namespace has to be refused with a
                        --  status, not accepted or ignored.
                        Controller.Write_Block_Command
                          (IO_Submission, IO_Slot, Next_ID,
                           Controller.Opcode_Read, 1,
                           Block_Count + 16, 1, Read_Buffer_Device);
                        declare
                           Answer : constant Controller.Completion := Run_IO;
                        begin
                           Harness.Check
                             (Answer.Status /= 0,
                              "reading past the end of the namespace is"
                              & " refused with a status of 0x"
                              & Hex_16 (Answer.Status)
                              & " rather than quietly accepted");
                        end;
                        Next_ID := Next_ID + 1;
                     end;

                     ------------------------------------------------------
                     --  Take the queues down again
                     ------------------------------------------------------

                     --  The submission queue first, this time: a completion
                     --  queue still serving a submission queue cannot be
                     --  removed. The orderings are mirror images.
                     Controller.Write_Delete_Queue_Command
                       (Submission, Admin_Slot, Next_ID,
                        Controller.Opcode_Delete_Submission_Queue, IO_Queue);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "removing the I/O submission queue succeeded");
                     Next_ID := Next_ID + 1;

                     Controller.Write_Delete_Queue_Command
                       (Submission, Admin_Slot, Next_ID,
                        Controller.Opcode_Delete_Completion_Queue, IO_Queue);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "removing the I/O completion queue succeeded");
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
