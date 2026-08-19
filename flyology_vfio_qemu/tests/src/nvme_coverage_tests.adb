--  Measures how much of the NVMe command set this controller implements,
--  and how much of that the functional tests exercise.
--
--  Reading a device's source to decide what to test has an obvious failure
--  mode: the reading is done once, by hand, against whatever version was
--  current, and nothing notices when it stops being true. This program asks
--  the controller instead. It issues every opcode, feature identifier and
--  log identifier in turn and records what came back, so the answer is
--  produced by the device that is actually present.
--
--  The distinction it relies on is the status code. A controller that does
--  not implement an opcode answers Invalid Command Opcode, which is a
--  different answer from a controller that implements it and rejects the
--  arguments. So "implemented" here means "answered with anything other
--  than Invalid Command Opcode".
--
--  That test has a known weakness, and it has already misled this
--  repository once. A controller may validate other fields before it
--  checks the opcode, so a command with a wrong namespace can be refused
--  as Invalid Namespace and counted present when the opcode is defined by
--  nothing at all. That is exactly what happened to an entry mislabelled
--  0Dh here when Zone Append is 7Dh: the probe reported it implemented,
--  and only driving it functionally found otherwise. A probe counts what
--  answers, which is not quite the same as what exists.
--
--  The report then compares that surface against the list of commands the
--  functional tests drive, and fails when the functional tests fall behind
--  a floor recorded below. That is what makes this a test rather than a
--  document: coverage that silently decays is the thing being guarded
--  against.
--
--  Some commands are deliberately not probed, and the reasons differ:
--  Asynchronous Event Request never completes until an event occurs and
--  would hang the probe; Format, Sanitize, firmware download and the
--  security commands either destroy data or take long enough to be
--  unhelpful. They are listed as skipped rather than quietly omitted.

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
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.NVMe;
with Harness;
with Interfaces;
with System.Storage_Elements;

procedure NVMe_Coverage_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package Controller renames Flyology_VFIO_QEMU.NVMe;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type SSE.Storage_Offset;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  Every structure gets a page of its own, and they are listed together
   --  so that two of them overlapping is visible rather than arithmetical.
   --  An earlier version had the probe's namespace queues at one address:
   --  completions overwrote the commands that produced them, and the
   --  controller then followed pointers out of the wreckage until the
   --  IOMMU stopped it.
   Submission_Offset    : constant DMA.Byte_Count := 0;
   Completion_Offset    : constant DMA.Byte_Count := 4096;
   Buffer_Offset        : constant DMA.Byte_Count := 8192;
   IO_Submission_Offset : constant DMA.Byte_Count := 12288;
   IO_Completion_Offset : constant DMA.Byte_Count := 16384;
   Scratch_Bytes        : constant := 20480;

   Queue_Entries     : constant Positive := 16;

   --  The status a controller returns for a command it does not have.
   Invalid_Opcode : constant U16 := 16#01#;

   --  What the probe returns for a command that never answered at all.
   --  Not a status any controller produces: a real one fits in eleven
   --  bits, so this cannot be mistaken for one.
   Stall_Status : constant U16 := 16#FFFF#;

   --  A command with a name, so the report reads as a command set rather
   --  than as a column of numbers.
   --  The opcode is kept as a plain byte here because a report has to
   --  describe both command sets in one shape; it is converted back to its
   --  proper type at the point of use, where the queue is known.
   type Command_Description is record
      Opcode : U8;
      Name   : String (1 .. 28);
      Probe  : Boolean;
      Reason : String (1 .. 44);
   end record;

   function Described
     (Opcode : U8; Name : String; Probe : Boolean := True;
      Reason : String := "") return Command_Description
   is
      Padded_Name   : String (1 .. 28) := (others => ' ');
      Padded_Reason : String (1 .. 44) := (others => ' ');
   begin
      Padded_Name (1 .. Name'Length) := Name;
      Padded_Reason (1 .. Reason'Length) := Reason;
      return (Opcode, Padded_Name, Probe, Padded_Reason);
   end Described;

   function Trim (Text : String) return String is
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then Text (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Trim;

   type Command_List is array (Positive range <>) of Command_Description;

   --  The admin command set, as the specification defines it.
   Admin_Commands : constant Command_List :=
     [Described (16#00#, "Delete I/O Submission Queue"),
      Described (16#01#, "Create I/O Submission Queue"),
      Described (16#02#, "Get Log Page"),
      Described (16#04#, "Delete I/O Completion Queue"),
      Described (16#05#, "Create I/O Completion Queue"),
      Described (16#06#, "Identify"),
      Described (16#08#, "Abort"),
      Described (16#09#, "Set Features"),
      Described (16#0A#, "Get Features"),
      Described (16#0C#, "Asynchronous Event Req", False,
                 "never completes until an event occurs"),
      Described (16#0D#, "Namespace Management"),
      Described (16#10#, "Firmware Commit", False,
                 "changes what the device boots"),
      Described (16#11#, "Firmware Image Download", False,
                 "changes what the device boots"),
      Described (16#14#, "Device Self-test"),
      Described (16#15#, "Namespace Attachment"),
      Described (16#18#, "Keep Alive"),
      Described (16#19#, "Directive Send"),
      Described (16#1A#, "Directive Receive"),
      Described (16#1C#, "Virtualization Management"),
      Described (16#7C#, "Doorbell Buffer Config"),
      Described (16#80#, "Format NVM", False, "destroys the namespace"),
      Described (16#81#, "Security Send", False, "opaque to this harness"),
      Described (16#82#, "Security Receive", False, "opaque to this harness"),
      Described (16#84#, "Sanitize", False, "destroys the namespace"),
      Described (16#86#, "Get LBA Status")];

   --  The command set that operates on a namespace.
   IO_Commands : constant Command_List :=
     [Described (16#00#, "Flush"),
      Described (16#01#, "Write"),
      Described (16#02#, "Read"),
      Described (16#04#, "Write Uncorrectable"),
      Described (16#05#, "Compare"),
      Described (16#08#, "Write Zeroes"),
      Described (16#09#, "Dataset Management"),
      Described (16#0C#, "Verify"),
      Described (16#0E#, "Reservation Register"),
      Described (16#11#, "Reservation Report"),
      Described (16#15#, "Reservation Acquire"),
      Described (16#19#, "Copy"),
      Described (16#79#, "Zone Management Send"),
      Described (16#7A#, "Zone Management Receive"),
      Described (16#7D#, "Zone Append")];

   --  The commands the functional suite actually drives. Coverage is the
   --  ratio of this to what the controller turns out to implement, and the
   --  floor below is what stops that ratio quietly falling.
   type Admin_Opcode_List is
     array (Positive range <>) of Controller.Admin_Opcode;
   type IO_Opcode_List is
     array (Positive range <>) of Controller.IO_Opcode;

   Exercised_Admin : constant Admin_Opcode_List :=
     [16#00#, 16#01#, 16#02#, 16#04#, 16#05#, 16#06#, 16#08#, 16#09#,
      16#0A#, 16#15#, 16#19#, 16#1A#, 16#7C#];
   Exercised_IO : constant IO_Opcode_List :=
     [16#00#, 16#01#, 16#02#, 16#04#, 16#05#, 16#08#, 16#09#, 16#0C#,
      16#19#, 16#79#, 16#7A#, 16#7D#];

   --  What the functional suite reached when this floor was last reviewed.
   --  A number below it means coverage has been lost.
   Admin_Coverage_Floor : constant := 13;
   IO_Coverage_Floor    : constant := 12;

   function Is_Exercised
     (Opcode : Controller.Admin_Opcode;
      Among  : Admin_Opcode_List) return Boolean
   is
      use type Controller.Admin_Opcode;
   begin
      for Candidate of Among loop
         if Candidate = Opcode then
            return True;
         end if;
      end loop;
      return False;
   end Is_Exercised;

   function Is_Exercised
     (Opcode : Controller.IO_Opcode; Among : IO_Opcode_List) return Boolean
   is
      use type Controller.IO_Opcode;
   begin
      for Candidate of Among loop
         if Candidate = Opcode then
            return True;
         end if;
      end loop;
      return False;
   end Is_Exercised;
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
      Config.Enable_Bus_Mastering (Device);

      declare
         BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (BAR, Device, Controller.Register_BAR);

         declare
            Capabilities : constant U64 :=
              Reg.Read_64 (BAR, Controller.Capabilities_Register);
            Stride : constant Positive :=
              Controller.Doorbell_Stride (Capabilities);

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
               pragma Unreferenced (Bound);

               Host : constant System.Address :=
                 DMA.Regions.Base_Address (Area);

               Submission : constant Controller.Queue_Location :=
                 (Kind    => Controller.Admin,
                  Host    => Host + SSE.Storage_Offset (Submission_Offset),
                  Device  => U64 (Window_Base) + U64 (Submission_Offset),
                  Entries => Queue_Entries);
               Completion : constant Controller.Queue_Location :=
                 (Kind    => Controller.Admin,
                  Host    => Host + SSE.Storage_Offset (Completion_Offset),
                  Device  => U64 (Window_Base) + U64 (Completion_Offset),
                  Entries => Queue_Entries);
               Buffer_Device : constant U64 :=
                 U64 (Window_Base) + U64 (Buffer_Offset);

               Everything : array (1 .. Scratch_Bytes) of U8
                 with Import, Volatile, Address => Host;

               Slot    : Natural := 0;
               Phase   : Boolean := True;
               Next_ID : U16 := 1;

               function Run return Controller.Completion;

               --  Set when a command never completed. A probe must survive
               --  a device that does not answer: the whole point is to
               --  find out what happens, and a tool that aborts on the
               --  first surprise reports nothing about anything after it.
               Stalled : Boolean := False;

               function Run return Controller.Completion is
                  Answer : Controller.Completion;
               begin
                  Controller.Ring_Submission_Doorbell
                    (BAR, Stride, Queue => 0,
                     Tail => (Slot + 1) mod Queue_Entries);
                  begin
                     Answer := Controller.Await_Completion
                       (Completion, Slot, Phase, Attempts => 2_000);
                  exception
                     when Device_Misbehaved =>
                        Stalled := True;
                        return (Identifier => 0, Status => Stall_Status,
                                Phase => Phase);
                  end;
                  Controller.Ring_Completion_Doorbell
                    (BAR, Stride, Queue => 0,
                     Head => (Slot + 1) mod Queue_Entries);
                  Slot := (Slot + 1) mod Queue_Entries;
                  if Slot = 0 then
                     Phase := not Phase;
                  end if;
                  Next_ID := Next_ID + 1;
                  return Answer;
               end Run;

               Admin_Present : Natural := 0;
               Admin_Covered : Natural := 0;
               Skipped       : Natural := 0;

               procedure Restart;

               --  Puts the queues back to a known state between sweeps.
               --
               --  A completion queue is recognised by a phase bit that
               --  flips each time the queue wraps, so a sweep that leaves
               --  the queue part-way round hands the next sweep entries it
               --  wrote itself. The symptom is a report that disagrees
               --  with the functional tests about what the controller
               --  supports — which is exactly what this probe did before
               --  it did this, claiming the health log was refused while
               --  nvme_tests was reading it successfully.
               --
               --  Disabling and re-enabling the controller resets its own
               --  head and tail as well as this program's, which is the
               --  only way to be sure both agree.
               procedure Restart is
               begin
                  Controller.Disable (BAR);
                  Everything := (others => 0);
                  Slot := 0;
                  Phase := True;
                  Stalled := False;
                  Controller.Enable (BAR, Submission, Completion);
               end Restart;
            begin
               Everything := (others => 0);
               Controller.Disable (BAR);
               Controller.Enable (BAR, Submission, Completion);
               Harness.Check
                 (Controller.Is_Ready (BAR),
                  "the controller is ready, so the probe can begin");

               Harness.Note ("");
               Harness.Note ("admin command set:");

               for Command of Admin_Commands loop
                  if not Command.Probe then
                     Skipped := Skipped + 1;
                     Harness.Note
                       ("  0x" & Hex_16 (U16 (Command.Opcode)) & "  "
                        & Command.Name & "  not probed: "
                        & Trim (Command.Reason));
                  else
                     --  Every probe carries a data pointer and a namespace,
                     --  because a command that needs one and is given none
                     --  answers Invalid Field rather than Invalid Opcode —
                     --  which would still count as implemented, but says
                     --  less.
                     Controller.Write_Admin_Command
                       (Submission, Slot,
                        Controller.Admin_Opcode (Command.Opcode), Next_ID,
                        Namespace => 1, DPTR1 => Buffer_Device,
                        CDW10 => 0);
                     declare
                        Answer  : constant Controller.Completion := Run;
                        --  A command that never answered is not evidence
                          --  that the opcode exists. Counting the stall as
                          --  present inflates the tally and props up the
                          --  floor beneath it.
                        Present : constant Boolean :=
                          Answer.Status /= Stall_Status
                          and then Answer.Status /= Invalid_Opcode
                          and then (Answer.Status and 16#7FF#)
                                   /= Invalid_Opcode;
                        Covered : constant Boolean :=
                          Is_Exercised
                            (Controller.Admin_Opcode (Command.Opcode),
                             Exercised_Admin);
                     begin
                        if Present then
                           Admin_Present := Admin_Present + 1;
                           if Covered then
                              Admin_Covered := Admin_Covered + 1;
                           end if;
                        end if;
                        Harness.Note
                          ("  0x" & Hex_16 (U16 (Command.Opcode)) & "  "
                           & Command.Name & "  "
                           & (if Present then "implemented"
                              else "absent     ")
                           & "  status 0x" & Hex_16 (Answer.Status)
                           & (if Present and then Covered
                              then "  exercised" else ""));
                     end;
                  end if;
               end loop;

               Harness.Note ("");
               Harness.Check
                 (Admin_Present > 0,
                  "the controller implements at least one admin command,"
                  & " so the probe is measuring something");
               Harness.Note
                 ("admin: " & Natural'Image (Admin_Covered) & " of"
                  & Natural'Image (Admin_Present)
                  & " implemented commands are exercised,"
                  & Natural'Image (Skipped) & " not probed");
               Harness.Check
                 (Admin_Covered >= Admin_Coverage_Floor,
                  "the functional suite still drives at least"
                  & Natural'Image (Admin_Coverage_Floor)
                  & " of the admin commands this controller implements");

               ---------------------------------------------------------
               --  The namespace command set needs a queue to run in
               ---------------------------------------------------------

               declare
                  IO_Present : Natural := 0;
                  IO_Covered : Natural := 0;
                  IO_Queue   : constant Controller.Queue_Identifier := 1;
                  IO_Sub : constant Controller.Queue_Location :=
                    (Kind    => Controller.Namespace_IO,
                     Host    =>
                       Host + SSE.Storage_Offset (IO_Submission_Offset),
                     Device  =>
                       U64 (Window_Base) + U64 (IO_Submission_Offset),
                     Entries => Queue_Entries);
                  IO_Comp : constant Controller.Queue_Location :=
                    (Kind    => Controller.Namespace_IO,
                     Host    =>
                       Host + SSE.Storage_Offset (IO_Completion_Offset),
                     Device  =>
                       U64 (Window_Base) + U64 (IO_Completion_Offset),
                     Entries => Queue_Entries);
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
                       (IO_Comp, IO_Slot, IO_Phase);
                     Controller.Ring_Completion_Doorbell
                       (BAR, Stride, Queue => IO_Queue,
                        Head => (IO_Slot + 1) mod Queue_Entries);
                     IO_Slot := (IO_Slot + 1) mod Queue_Entries;
                     if IO_Slot = 0 then
                        IO_Phase := not IO_Phase;
                     end if;
                     Next_ID := Next_ID + 1;
                     return Answer;
                  end Run_IO;
               begin
                  Controller.Write_Create_Completion_Queue_Command
                    (Submission, Slot, Next_ID, IO_Queue, Queue_Entries,
                     IO_Comp.Device);
                  Harness.Check_Equal
                    (U32 (Run.Status), 0,
                     "a completion queue for the probe was created");

                  Controller.Write_Create_Submission_Queue_Command
                    (Submission, Slot, Next_ID, IO_Queue, IO_Queue,
                     Queue_Entries, IO_Sub.Device);
                  Harness.Check_Equal
                    (U32 (Run.Status), 0,
                     "a submission queue for the probe was created");

                  Harness.Note ("");
                  Harness.Note ("namespace command set:");

                  for Command of IO_Commands loop
                     Controller.Write_IO_Command
                       (IO_Sub, IO_Slot,
                        Controller.IO_Opcode (Command.Opcode), Next_ID,
                        Namespace => 1, DPTR1 => Buffer_Device,
                        CDW10 => 0, CDW12 => 0);
                     declare
                        Answer  : constant Controller.Completion := Run_IO;
                        Present : constant Boolean :=
                          Answer.Status /= Stall_Status
                          and then (Answer.Status and 16#7FF#)
                                   /= Invalid_Opcode;
                        Covered : constant Boolean :=
                          Is_Exercised
                            (Controller.IO_Opcode (Command.Opcode),
                             Exercised_IO);
                     begin
                        if Present then
                           IO_Present := IO_Present + 1;
                           if Covered then
                              IO_Covered := IO_Covered + 1;
                           end if;
                        end if;
                        Harness.Note
                          ("  0x" & Hex_16 (U16 (Command.Opcode)) & "  "
                           & Command.Name & "  "
                           & (if Present then "implemented"
                              else "absent     ")
                           & "  status 0x" & Hex_16 (Answer.Status)
                           & (if Present and then Covered
                              then "  exercised" else ""));
                     end;
                  end loop;

                  Harness.Note ("");
                  Harness.Note
                    ("namespace:" & Natural'Image (IO_Covered) & " of"
                     & Natural'Image (IO_Present)
                     & " implemented commands are exercised");
                  Harness.Check
                    (IO_Present > 0,
                     "the controller implements namespace commands");
                  Harness.Check
                    (IO_Covered >= IO_Coverage_Floor,
                     "the functional suite still drives at least"
                     & Natural'Image (IO_Coverage_Floor)
                     & " of the namespace commands this controller"
                     & " implements");

                  Controller.Write_Delete_Queue_Command
                    (Submission, Slot, Next_ID,
                     Controller.Opcode_Delete_Submission_Queue, IO_Queue);
                  Harness.Check_Equal
                    (U32 (Run.Status), 0, "the probe's queues are removed");
                  Controller.Write_Delete_Queue_Command
                    (Submission, Slot, Next_ID,
                     Controller.Opcode_Delete_Completion_Queue, IO_Queue);
                  Harness.Check_Equal (U32 (Run.Status), 0, "both of them");
               end;

               ---------------------------------------------------------
               --  Features and logs
               ---------------------------------------------------------

               declare
                  Features_Present : Natural := 0;
                  Logs_Present     : Natural := 0;
               begin
                  Restart;
                  Harness.Note ("");
                  Harness.Note ("features the controller answers:");
                  for Feature in Controller.Feature_Identifier
                    range 0 .. 16#1F#
                  loop
                     exit when Stalled;
                     Controller.Write_Feature_Command
                       (Submission, Slot, Next_ID,
                        Controller.Opcode_Get_Features, Feature);
                     declare
                        Answer : constant Controller.Completion := Run;
                     begin
                        if Answer.Status = 0 then
                           Features_Present := Features_Present + 1;
                           Harness.Note
                             ("  0x" & Hex_16 (U16 (Feature))
                              & "  answered, value 0x"
                              & Hex_32 (Controller.Completion_Result
                                          (Completion,
                                           (Slot + Queue_Entries - 1)
                                           mod Queue_Entries)));
                        elsif Answer.Status /= 16#FFFF# then
                           --  Reported rather than dropped. A feature the
                           --  controller refuses is as much a fact about
                           --  it as one it answers, and a report showing
                           --  only successes cannot be checked against
                           --  anything.
                           Harness.Note
                             ("  0x" & Hex_16 (U16 (Feature))
                              & "  refused, status 0x"
                              & Hex_16 (Answer.Status));
                        end if;
                     end;
                  end loop;
                  Harness.Note
                    ("  " & Natural'Image (Features_Present)
                     & " of 32 feature identifiers are answered without a"
                     & " namespace");
                  Harness.Check
                    (Features_Present >= 4,
                     "the controller answers a useful number of features");

                  Restart;
                  Harness.Note ("");
                  Harness.Note ("logs the controller answers:");
                  for Log in Controller.Log_Identifier range 1 .. 16#0A# loop
                     exit when Stalled;
                     Controller.Write_Log_Page_Command
                       (Submission, Slot, Next_ID, Log, 512, Buffer_Device);
                     declare
                        Answer : constant Controller.Completion := Run;
                     begin
                        if Answer.Status = 0 then
                           Logs_Present := Logs_Present + 1;
                           Harness.Note
                             ("  0x" & Hex_16 (U16 (Log)) & "  answered");
                        elsif Answer.Status = 16#FFFF# then
                           Harness.Note
                             ("  0x" & Hex_16 (U16 (Log))
                              & "  no completion arrived");
                        else
                           Harness.Note
                             ("  0x" & Hex_16 (U16 (Log))
                              & "  refused, status 0x"
                              & Hex_16 (Answer.Status));
                        end if;
                     end;
                  end loop;

                  if Stalled then
                     Harness.Note
                       ("  the controller stopped answering partway through"
                        & " the log sweep; what is above is what it did"
                        & " answer");
                  end if;
                  Harness.Note
                    ("  " & Natural'Image (Logs_Present)
                     & " of 16 log identifiers are answered");
                  Harness.Check
                    (Logs_Present >= 2,
                     "the controller answers at least the error and health"
                     & " logs");
               end;

               Controller.Disable (BAR);
            exception
               --  Also on the way out through an exception, not only on
               --  the way out through the end. A device is not finished
               --  with a ring because the program that programmed it has
               --  stopped caring: the mapping goes away as this block
               --  unwinds, and anything still writing there writes to an
               --  address the IOMMU no longer translates. The fault storm
               --  that follows buries whatever raised in the first place.
               when others =>
                  begin
                     Controller.Disable (BAR);
                  exception
                     when others => null;
                  end;
                  raise;
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   Harness.Report ("nvme_coverage_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("the whole probe", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("nvme_coverage_tests");
end NVMe_Coverage_Tests;
