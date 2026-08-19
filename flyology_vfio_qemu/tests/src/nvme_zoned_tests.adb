--  The zoned command set, and attaching a namespace at run time.
--
--  These commands exist on a namespace configured for them and nowhere
--  else, which is why the coverage probe could report every one of them as
--  implemented while none had ever done anything: the probe counts what is
--  present in the command-set table, and the table is a property of the
--  controller rather than of the namespace being addressed.
--
--  So the virtual machine now carries three namespaces. The first is
--  ordinary and carries the block tests. The second is zoned, which is what
--  makes the commands below more than table entries. The third starts
--  detached, so that attaching it is something a test can do rather than
--  something that has already happened.
--
--  A zone is a region that must be written forwards. What makes it worth
--  having is Zone Append: a writer does not name a block, it names the
--  zone, and the controller replies with where the data went. Several
--  writers can therefore append to one zone without agreeing a position
--  first, which is the property the whole command set exists for and the
--  one checked most carefully here.

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

procedure NVMe_Zoned_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package Controller renames Flyology_VFIO_QEMU.NVMe;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type DMA.Byte_Count;
   use type DMA.IOVA_Address;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type SSE.Storage_Offset;
   use type Controller.Zone_State;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   Admin_Sub_Offset  : constant DMA.Byte_Count := 0;
   Admin_Comp_Offset : constant DMA.Byte_Count := 4096;
   IO_Sub_Offset     : constant DMA.Byte_Count := 8192;
   IO_Comp_Offset    : constant DMA.Byte_Count := 12288;
   Report_Offset     : constant DMA.Byte_Count := 16384;
   Data_Offset       : constant DMA.Byte_Count := 20480;
   List_Offset       : constant DMA.Byte_Count := 24576;
   Scratch_Bytes     : constant := 28672;

   Queue_Entries : constant Positive := 16;
   IO_Queue      : constant Controller.Queue_Identifier := 1;

   --  The zoned namespace the machine attaches, and the detached one.
   Zoned_Namespace    : constant Controller.Namespace_Identifier := 2;
   Detached_Namespace : constant Controller.Namespace_Identifier := 3;
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
            Area : constant DMA.Regions.Region :=
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

               function At_Host (Offset : DMA.Byte_Count)
                 return System.Address
               is (Host + SSE.Storage_Offset (Offset));

               function At_Device (Offset : DMA.Byte_Count)
                 return Device_Address
               is (Window_Base + Device_Address (Offset));

               Admin_Sub : constant Controller.Queue_Location :=
                 (Kind    => Controller.Admin,
                  Host    => At_Host (Admin_Sub_Offset),
                  Device  => At_Device (Admin_Sub_Offset),
                  Entries => Queue_Entries);
               Admin_Comp : constant Controller.Queue_Location :=
                 (Kind    => Controller.Admin,
                  Host    => At_Host (Admin_Comp_Offset),
                  Device  => At_Device (Admin_Comp_Offset),
                  Entries => Queue_Entries);
               IO_Sub : constant Controller.Queue_Location :=
                 (Kind    => Controller.Namespace_IO,
                  Host    => At_Host (IO_Sub_Offset),
                  Device  => At_Device (IO_Sub_Offset),
                  Entries => Queue_Entries);
               IO_Comp : constant Controller.Queue_Location :=
                 (Kind    => Controller.Namespace_IO,
                  Host    => At_Host (IO_Comp_Offset),
                  Device  => At_Device (IO_Comp_Offset),
                  Entries => Queue_Entries);

               Everything : array (1 .. Scratch_Bytes) of U8
                 with Import, Volatile, Address => Host;
               Data_Bytes : array (0 .. 4095) of U8
                 with Import, Volatile, Address => At_Host (Data_Offset);

               Admin_Slot : Natural := 0;
               IO_Slot    : Natural := 0;
               Next_ID    : U16 := 1;

               function Run_Admin return Controller.Completion;
               function Run_IO return Controller.Completion;

               function Run_Admin return Controller.Completion is
                  Answer : Controller.Completion;
               begin
                  Controller.Ring_Submission_Doorbell
                    (BAR, Stride, Controller.Admin_Queue,
                     (Admin_Slot + 1) mod Queue_Entries);
                  Answer := Controller.Await_Completion
                    (Admin_Comp, Admin_Slot, True);
                  Controller.Ring_Completion_Doorbell
                    (BAR, Stride, Controller.Admin_Queue,
                     (Admin_Slot + 1) mod Queue_Entries);
                  Admin_Slot := Admin_Slot + 1;
                  Next_ID := Next_ID + 1;
                  return Answer;
               end Run_Admin;

               function Run_IO return Controller.Completion is
                  Answer : Controller.Completion;
               begin
                  Controller.Ring_Submission_Doorbell
                    (BAR, Stride, IO_Queue,
                     (IO_Slot + 1) mod Queue_Entries);
                  Answer := Controller.Await_Completion
                    (IO_Comp, IO_Slot, True);
                  Controller.Ring_Completion_Doorbell
                    (BAR, Stride, IO_Queue,
                     (IO_Slot + 1) mod Queue_Entries);
                  IO_Slot := IO_Slot + 1;
                  Next_ID := Next_ID + 1;
                  return Answer;
               end Run_IO;

               Zone_Start : U64 := 0;
            begin
               Everything := (others => 0);
               Controller.Disable (BAR);
               Controller.Enable (BAR, Admin_Sub, Admin_Comp);

               Harness.Note
                 ("capabilities 0x"
                  & Hex_32 (U32 (Interfaces.Shift_Right (Capabilities, 32)))
                  & Hex_32 (U32 (Capabilities and 16#FFFF_FFFF#))
                  & ", more than one command set: "
                  & Boolean'Image
                      (Controller.Supports_Multiple_Command_Sets
                         (Capabilities)));
               Harness.Note
                 ("configuration reads back 0x"
                  & Hex_32 (Reg.Read_32
                              (BAR, Controller.Configuration_Register)));

               Controller.Write_Create_Completion_Queue_Command
                 (Admin_Sub, Admin_Slot, Next_ID, IO_Queue, Queue_Entries,
                  IO_Comp.Device);
               Harness.Check_Equal
                 (U32 (Run_Admin.Status), 0, "a queue pair was created");
               Controller.Write_Create_Submission_Queue_Command
                 (Admin_Sub, Admin_Slot, Next_ID, IO_Queue, IO_Queue,
                  Queue_Entries, IO_Sub.Device);
               Harness.Check_Equal (U32 (Run_Admin.Status), 0, "both of it");

               ------------------------------------------------------
               --  Describing zones
               ------------------------------------------------------

               Controller.Write_Zone_Report_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, 0, 4096,
                  At_Device (Report_Offset));
               declare
                  Answer : constant Controller.Completion := Run_IO;
               begin
                  if Answer.Status /= 0 then
                     Harness.Skip
                       ("every zoned check",
                        "namespace" & Controller.Namespace_Identifier'Image
                          (Zoned_Namespace)
                        & " refused a zone report with status 0x"
                        & Hex_16 (Answer.Status) & ", so it is not zoned"
                        & " on this machine");
                     Harness.Report ("nvme_zoned_tests");
                     return;
                  end if;
               end;

               declare
                  Count : constant U64 :=
                    Controller.Reported_Zones (At_Host (Report_Offset));
                  First : constant Controller.Zone_Description :=
                    Controller.Reported_Zone (At_Host (Report_Offset), 0);
               begin
                  Harness.Note
                    ("the namespace has" & U64'Image (Count) & " zones;"
                     & " the first starts at" & U64'Image (First.Start)
                     & " holds" & U64'Image (First.Capacity)
                     & " blocks and is "
                     & Controller.Zone_State'Image (First.State));
                  Harness.Check
                    (Count > 1,
                     "the namespace is divided into more than one zone,"
                     & " which is what makes it zoned rather than merely"
                     & " willing to answer the question");
                  Harness.Check
                    (First.Capacity > 0, "the first zone can hold blocks");
                  Zone_Start := First.Start;
               end;

               --  Emptied first, so the checks below start from a state
               --  this test set rather than one a previous run left.
               Controller.Write_Zone_Action_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, 0,
                  Controller.Reset, All_Zones => True);
               Harness.Check_Equal
                 (U32 (Run_IO.Status), 0, "every zone was reset");

               Controller.Write_Zone_Report_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, 0, 4096,
                  At_Device (Report_Offset));
               Harness.Check_Equal
                 (U32 (Run_IO.Status), 0, "and described again");

               declare
                  First : constant Controller.Zone_Description :=
                    Controller.Reported_Zone (At_Host (Report_Offset), 0);
               begin
                  Harness.Check
                    (First.State = Controller.Empty,
                     "the first zone is empty after the reset");
                  Harness.Check
                    (First.Write_Pointer = First.Start,
                     "and its write pointer is back at its start");
               end;

               ------------------------------------------------------
               --  Appending, which is what a zone is for
               ------------------------------------------------------

               for Index in Data_Bytes'Range loop
                  Data_Bytes (Index) := U8 ((Index * 5 + 1) mod 256);
               end loop;

               declare
                  First_At  : U64;
                  Second_At : U64;
               begin
                  Controller.Write_Zone_Append_Command
                    (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, Zone_Start,
                     1, At_Device (Data_Offset));
                  declare
                     Slot_Used : constant Natural := IO_Slot;
                  begin
                     Harness.Check_Equal
                       (U32 (Run_IO.Status), 0, "an append succeeded");
                     First_At := Controller.Appended_At (IO_Comp, Slot_Used);
                  end;

                  Harness.Check
                    (First_At = Zone_Start,
                     "and the controller reported it landed at the start of"
                     & " the empty zone, which the caller did not choose");

                  Controller.Write_Zone_Append_Command
                    (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, Zone_Start,
                     1, At_Device (Data_Offset));
                  declare
                     Slot_Used : constant Natural := IO_Slot;
                  begin
                     Harness.Check_Equal
                       (U32 (Run_IO.Status), 0, "a second append succeeded");
                     Second_At := Controller.Appended_At (IO_Comp, Slot_Used);
                  end;

                  Harness.Check
                    (Second_At > First_At,
                     "and landed after the first, at a block the controller"
                     & " chose and reported rather than one this program"
                     & " named: that is the property the whole command set"
                     & " exists for");
               end;

               Controller.Write_Zone_Report_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, 0, 4096,
                  At_Device (Report_Offset));
               Harness.Check_Equal (U32 (Run_IO.Status), 0, "described again");

               declare
                  First : constant Controller.Zone_Description :=
                    Controller.Reported_Zone (At_Host (Report_Offset), 0);
               begin
                  Harness.Check
                    (First.Write_Pointer > First.Start,
                     "the zone's write pointer has moved past its start");
                  Harness.Check
                    (First.State = Controller.Implicitly_Open
                       or else First.State = Controller.Explicitly_Open,
                     "and it is open, having been written without being"
                     & " opened first");
               end;

               ------------------------------------------------------
               --  Changing a zone's state on purpose
               ------------------------------------------------------

               Controller.Write_Zone_Action_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, Zone_Start,
                  Controller.Finish);
               Harness.Check_Equal
                 (U32 (Run_IO.Status), 0, "the zone was finished");

               Controller.Write_Zone_Report_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, 0, 4096,
                  At_Device (Report_Offset));
               Harness.Check_Equal (U32 (Run_IO.Status), 0, "and described");

               Harness.Check
                 (Controller.Reported_Zone
                    (At_Host (Report_Offset), 0).State = Controller.Full,
                  "a finished zone reports itself full, whatever its write"
                  & " pointer had reached");

               --  Appending to a full zone must fail. A zoned namespace
               --  whose state meant nothing would accept it.
               Controller.Write_Zone_Append_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, Zone_Start, 1,
                  At_Device (Data_Offset));
               Harness.Check
                 (Run_IO.Status /= 0,
                  "appending to a full zone is refused, so the state the"
                  & " report describes is one the controller enforces");

               Controller.Write_Zone_Action_Command
                 (IO_Sub, IO_Slot, Next_ID, Zoned_Namespace, Zone_Start,
                  Controller.Reset);
               Harness.Check_Equal
                 (U32 (Run_IO.Status), 0, "and the zone was reset again");

               ------------------------------------------------------
               --  Attaching a namespace that was not there
               ------------------------------------------------------

               --  Detached first. A namespace in a subsystem is shared by
               --  default, so the one meant to start detached is already
               --  attached by the time a test reaches it, and attaching it
               --  again is refused as already-attached. Taking it away and
               --  putting it back exercises both directions and leaves the
               --  controller as it was found.
               Controller.Write_Controller_List (At_Host (List_Offset), 0);
               Controller.Write_Namespace_Attachment_Command
                 (Admin_Sub, Admin_Slot, Next_ID, Detached_Namespace,
                  Attach => False, List_Address => At_Device (List_Offset));
               declare
                  Answer : constant Controller.Completion := Run_Admin;
               begin
                  Harness.Note
                    ("detaching namespace"
                     & Controller.Namespace_Identifier'Image
                         (Detached_Namespace)
                     & " answered 0x" & Hex_16 (Answer.Status));
               end;

               Controller.Write_Controller_List (At_Host (List_Offset), 0);
               Controller.Write_Namespace_Attachment_Command
                 (Admin_Sub, Admin_Slot, Next_ID, Detached_Namespace,
                  Attach => True, List_Address => At_Device (List_Offset));
               declare
                  Answer : constant Controller.Completion := Run_Admin;
               begin
                  if Answer.Status = 0 then
                     Harness.Check
                       (True,
                        "a namespace that started detached was attached at"
                        & " run time");

                     Controller.Write_Admin_Command
                       (Admin_Sub, Admin_Slot, Controller.Opcode_Identify,
                        Next_ID, DPTR1 => At_Device (Report_Offset),
                        CDW10 => Controller.Identify_Active_Namespaces);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "and the active namespace list can be read again");

                     declare
                        Listed : array (0 .. 15) of U8 with Import, Volatile,
                          Address => At_Host (Report_Offset);
                        Found  : Boolean := False;
                     begin
                        for Index in 0 .. 3 loop
                           if Listed (Index * 4)
                                = U8 (Detached_Namespace)
                           then
                              Found := True;
                           end if;
                        end loop;
                        Harness.Check
                          (Found,
                           "which now names it, so the attachment took"
                           & " rather than merely being accepted");
                     end;
                  else
                     Harness.Skip
                       ("namespace attachment",
                        "the controller refused it with status 0x"
                        & Hex_16 (Answer.Status));
                  end if;
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

   Harness.Report ("nvme_zoned_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("nvme_zoned_tests");
end NVMe_Zoned_Tests;
