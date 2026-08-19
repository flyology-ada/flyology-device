--  Several queue pairs at once, each interrupting on a vector of its own.
--
--  This is the shape a real driver has and nothing here had yet: one queue
--  pair per core, each bound to its own MSI-X vector, work submitted to
--  whichever is nearest and completions collected by waiting rather than
--  spinning. A single queue polled in a loop proves the command set works
--  and proves nothing about the arrangement a driver would actually use.
--
--  Three things are worth separating, because a test that showed only the
--  first would look like success:
--
--  That each queue completes its own work. A controller that ignored the
--  queue identifier would still return completions, in the wrong queue.
--
--  That each queue interrupts on the vector it was bound to. A completion
--  queue whose vector field went astray would deliver everything on vector
--  zero and every command would still finish.
--
--  That work submitted to several queues before any is collected all
--  completes. Submitting and immediately waiting, one queue at a time,
--  exercises none of the concurrency the arrangement exists for.

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
with System;
with Interfaces;

procedure NVMe_Queues_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package Controller renames Flyology_VFIO_QEMU.NVMe;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package IRQ renames Flyology_VFIO.Interrupts;
   package Reg renames Flyology_VFIO.Registers;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_64;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  How many I/O queue pairs to build. Four is enough to show the
   --  arrangement and small enough that every one gets its own page.
   Pairs : constant := 4;

   Queue_Entries : constant Positive := 16;

   --  Page-aligned, one structure per page, laid out together so that two
   --  of them overlapping would be visible rather than arithmetical.
   Admin_Sub_Offset  : constant DMA.Byte_Count := 0;
   Admin_Comp_Offset : constant DMA.Byte_Count := 4096;
   IO_Sub_Base       : constant DMA.Byte_Count := 8192;
   IO_Comp_Base      : constant DMA.Byte_Count := 8192 + 4096 * Pairs;
   Buffer_Base       : constant DMA.Byte_Count := 8192 + 8192 * Pairs;
   Scratch_Bytes     : constant := 8192 + 12288 * Pairs;

   --  Vector zero belongs to the admin queue, which is created with the
   --  controller and signals there by definition. I/O queues start at one
   --  so that a completion arriving on zero is recognisably the admin
   --  queue rather than a queue whose binding was lost.
   First_IO_Vector : constant := 1;
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
         Vectors : constant IRQ.Interrupt_Details :=
           IRQ.Describe (Device, IRQ.MSI_X);
      begin
         if not Vectors.Implemented
           or else Vectors.Count < Pairs + 1
         then
            Harness.Skip
              ("every check",
               "this controller offers" & Natural'Image (Vectors.Count)
               & " MSI-X vectors and" & Natural'Image (Pairs + 1)
               & " are needed, one per queue pair plus the admin queue");
            Harness.Report ("nvme_queues_tests");
            return;
         end if;
      end;

      declare
         --  One event per vector. Separate objects because an Event is
         --  limited and finalizes itself; an array of them is not worth
         --  the machinery for five.
         Admin_Signal : IRQ.Event;
         Signal_1 : IRQ.Event;
         Signal_2 : IRQ.Event;
         Signal_3 : IRQ.Event;
         Signal_4 : IRQ.Event;

         Waiting : IRQ.Blocking_Waiter;
      begin
         IRQ.Open (Admin_Signal);
         IRQ.Open (Signal_1);
         IRQ.Open (Signal_2);
         IRQ.Open (Signal_3);
         IRQ.Open (Signal_4);

         declare
            Vector_Descriptors : constant IRQ.Vector_Descriptors :=
              [0 => IRQ.Descriptor (Admin_Signal),
               1 => IRQ.Descriptor (Signal_1),
               2 => IRQ.Descriptor (Signal_2),
               3 => IRQ.Descriptor (Signal_3),
               4 => IRQ.Descriptor (Signal_4)];

            --  Index n of this set is queue n, which is what makes the
            --  result of Wait_For_Any directly meaningful.
            IO_Signals : constant IRQ.Descriptor_Array :=
              [1 => IRQ.Descriptor (Signal_1),
               2 => IRQ.Descriptor (Signal_2),
               3 => IRQ.Descriptor (Signal_3),
               4 => IRQ.Descriptor (Signal_4)];
         begin
            IRQ.Enable (Device, IRQ.MSI_X, Vector_Descriptors);

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
                     --  Both addresses come from the mapping rather than being
                     --  recomputed beside it. It knows its own extent, so an offset
                     --  that would put a structure past the end of the region is
                     --  refused here instead of becoming an address the device
                     --  faults on.
                     function At_Host
                       (Offset : DMA.Byte_Count; Extent : DMA.Byte_Count := 1)
                        return System.Address
                     is (Bound.Host_At (Offset, Extent));

                     function At_Device
                       (Offset : DMA.Byte_Count; Extent : DMA.Byte_Count := 1)
                        return Device_Address
                     is (Bound.Device_At (Offset, Extent));

                     Host : constant System.Address := Bound.Host_At (0);

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

                     type Pair_Index is range 1 .. Pairs;
                     type Queue_Array is
                       array (Pair_Index) of Controller.Queue_Location;

                     function Submission_Of (Which : Pair_Index)
                       return Controller.Queue_Location
                     is (Kind    => Controller.Namespace_IO,
                         Host    =>
                           At_Host (IO_Sub_Base
                                    + 4096 * DMA.Byte_Count (Which - 1)),
                         Device  =>
                           At_Device (IO_Sub_Base
                                      + 4096 * DMA.Byte_Count (Which - 1)),
                         Entries => Queue_Entries);

                     function Completion_Of (Which : Pair_Index)
                       return Controller.Queue_Location
                     is (Kind    => Controller.Namespace_IO,
                         Host    =>
                           At_Host (IO_Comp_Base
                                    + 4096 * DMA.Byte_Count (Which - 1)),
                         Device  =>
                           At_Device (IO_Comp_Base
                                      + 4096 * DMA.Byte_Count (Which - 1)),
                         Entries => Queue_Entries);

                     Submissions : constant Queue_Array :=
                       [for Which in Pair_Index => Submission_Of (Which)];
                     Completions : constant Queue_Array :=
                       [for Which in Pair_Index => Completion_Of (Which)];

                     Everything : array (1 .. Scratch_Bytes) of U8
                       with Import, Volatile, Address => Host;

                     Admin_Slot : Natural := 0;
                     Next_ID    : U16 := 1;

                     function Run_Admin return Controller.Completion;

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

                     Built : Natural := 0;
                  begin
                     Everything := (others => 0);
                     Controller.Disable (BAR);
                     Controller.Enable (BAR, Admin_Sub, Admin_Comp);

                     --  Build every pair. Completion queue first for each,
                     --  since a submission queue naming one that does not
                     --  exist is refused.
                     for Which in Pair_Index loop
                        Controller.Write_Create_Completion_Queue_Command
                          (Admin_Sub, Admin_Slot, Next_ID,
                           Controller.Queue_Identifier (Which),
                           Queue_Entries, Completions (Which).Device,
                           Interrupt_Vector =>
                             Controller.Interrupt_Selection
                               (Integer (Which) - 1 + First_IO_Vector));
                        exit when Run_Admin.Status /= 0;

                        Controller.Write_Create_Submission_Queue_Command
                          (Admin_Sub, Admin_Slot, Next_ID,
                           Controller.Queue_Identifier (Which),
                           Controller.Queue_Identifier (Which),
                           Queue_Entries, Submissions (Which).Device);
                        exit when Run_Admin.Status /= 0;

                        Built := Built + 1;
                     end loop;

                     Harness.Check
                       (Built = Pairs,
                        "all" & Natural'Image (Pairs) & " queue pairs were"
                        & " created, each bound to a vector of its own");

                     --  Drain the admin vector: creating the pairs posted
                     --  completions there, and leaving them pending would
                     --  make the checks below read a stale signal.
                     --
                     --  Draining means waiting until it goes quiet rather
                     --  than taking once. A completion and its interrupt
                     --  are two separate things: the controller writes the
                     --  queue entry and then sends the message, and the
                     --  loop above finished as soon as it saw the entry.
                     --  One Take therefore collects the interrupts that had
                     --  arrived by then and leaves the last one in flight,
                     --  which is exactly the stale signal this is here to
                     --  prevent — and which made the final check below fail
                     --  about one run in two before it waited.
                     declare
                        Drained : U64 := 0;
                     begin
                        while Waiting.Wait_For (Admin_Signal, 0.05) loop
                           Drained := Drained + IRQ.Take (Admin_Signal);
                        end loop;
                        Harness.Check
                          (Drained > 0,
                           "the admin queue signalled its own vector while"
                           & " the pairs were being built");
                     end;
                     Harness.Check
                       (Waiting.Wait_For_Any (IO_Signals, 0.05) = 0,
                        "and no I/O vector had been signalled yet");

                     --  Submit to every queue before collecting any. This
                     --  is the part a one-queue-at-a-time test cannot
                     --  reach: several queues in flight together.
                     for Which in Pair_Index loop
                        Controller.Write_Block_Command
                          (Submissions (Which), 0, Next_ID,
                           Controller.Opcode_Read, 1,
                           U64 (Integer (Which) - 1) * 8, 1,
                           At_Device (Buffer_Base
                                      + 4096 * DMA.Byte_Count (Which - 1)));
                        Next_ID := Next_ID + 1;
                        Controller.Ring_Submission_Doorbell
                          (BAR, Stride,
                           Controller.Queue_Identifier (Which), 1);
                     end loop;

                     --  Collect by waiting. Each queue must announce
                     --  itself on its own vector, and every one must turn
                     --  up before this is done.
                     declare
                        Seen : array (Pair_Index) of Boolean :=
                          [others => False];
                        Rounds : Natural := 0;
                        All_Seen : Boolean := False;
                     begin
                        while not All_Seen and then Rounds < Pairs * 4 loop
                           declare
                              Ready : constant Natural :=
                                Waiting.Wait_For_Any (IO_Signals, 5.0);
                           begin
                              exit when Ready = 0;

                              declare
                                 Which : constant Pair_Index :=
                                   Pair_Index (Ready);
                                 Answer : constant Controller.Completion :=
                                   Controller.Read_Completion
                                     (Completions (Which), 0);
                                 Drained : Interfaces.Unsigned_64;
                              begin
                                 --  Drain the descriptor before waiting
                                 --  again. An eventfd stays readable until
                                 --  it is read, so a waiter that is not
                                 --  drained returns the same descriptor
                                 --  every time — and since the lowest
                                 --  ready index wins, the first queue
                                 --  would be reported forever and the
                                 --  others never.
                                 Drained :=
                                   (case Which is
                                       when 1 => IRQ.Take (Signal_1),
                                       when 2 => IRQ.Take (Signal_2),
                                       when 3 => IRQ.Take (Signal_3),
                                       when 4 => IRQ.Take (Signal_4));
                                 Harness.Check
                                   (Drained > 0,
                                    "queue" & Pair_Index'Image (Which)
                                    & " carried a signal count");
                                 Harness.Check
                                   (Answer.Phase,
                                    "queue" & Pair_Index'Image (Which)
                                    & " announced a completion that is"
                                    & " really in its own queue");
                                 Harness.Check_Equal
                                   (U32 (Answer.Status), 0,
                                    "and it succeeded");
                                 Seen (Which) := True;
                                 Controller.Ring_Completion_Doorbell
                                   (BAR, Stride,
                                    Controller.Queue_Identifier (Which), 1);
                              end;
                           end;

                           All_Seen := True;
                           for Which in Pair_Index loop
                              if not Seen (Which) then
                                 All_Seen := False;
                              end if;
                           end loop;
                           Rounds := Rounds + 1;
                        end loop;

                        Harness.Check
                          (All_Seen,
                           "every queue announced its own completion on its"
                           & " own vector, so the vector binding held for"
                           & " all" & Natural'Image (Pairs) & " of them and"
                           & " not merely the first");
                     end;

                     Harness.Check
                       (IRQ.Take (Admin_Signal) = 0,
                        "the admin vector stayed quiet throughout, so no"
                        & " I/O completion leaked onto it");

                     --  Take them down in the order the specification
                     --  requires: a completion queue still serving a
                     --  submission queue cannot be removed.
                     declare
                        Removed : Natural := 0;
                     begin
                        for Which in Pair_Index loop
                           Controller.Write_Delete_Queue_Command
                             (Admin_Sub, Admin_Slot, Next_ID,
                              Controller.Opcode_Delete_Submission_Queue,
                              Controller.Queue_Identifier (Which));
                           exit when Run_Admin.Status /= 0;
                           Controller.Write_Delete_Queue_Command
                             (Admin_Sub, Admin_Slot, Next_ID,
                              Controller.Opcode_Delete_Completion_Queue,
                              Controller.Queue_Identifier (Which));
                           exit when Run_Admin.Status /= 0;
                           Removed := Removed + 1;
                        end loop;
                        Harness.Check
                          (Removed = Pairs,
                           "and all of them were removed again");
                     end;

                     Controller.Disable (BAR);
                  exception
                     --  Also on the way out through an exception, not only on the way
                     --  out through the end. A device is not finished with a ring
                     --  because the program that programmed it has stopped caring:
                     --  the mapping goes away as this block unwinds, and anything
                     --  still writing there writes to an address the IOMMU no longer
                     --  translates — a fault storm that buries whatever raised.
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

            IRQ.Disable (Device, IRQ.MSI_X);
         end;
      end;
   end;

   Harness.Report ("nvme_queues_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("nvme_queues_tests");
end NVMe_Queues_Tests;
