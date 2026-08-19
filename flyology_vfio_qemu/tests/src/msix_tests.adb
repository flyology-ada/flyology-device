--  Interrupts that actually arrive, on the vector they were asked for.
--
--  Everything else in this repository polls. That is a defensible choice
--  for a data path and an indefensible one for everything else, and until
--  now it was not a choice at all: Flyology_VFIO.Interrupts.Enable had
--  never been called with more than one descriptor, so the variable-length
--  tail its request carries had never been exercised past a single entry.
--
--  This drives it properly. Several MSI-X vectors are enabled at once, each
--  on an eventfd of its own, and an NVMe completion queue is bound to a
--  chosen vector. A command is then submitted and the program waits — it
--  does not spin — until that vector, and no other, delivers.
--
--  The controller is the vehicle rather than the subject. What is under
--  test is Flyology_VFIO: the request layout for many vectors, the
--  delivery of each to its own descriptor, and the Waiter that turns a
--  descriptor into something a program can wait on.

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

procedure MSIX_Tests is
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
   use type DMA.IOVA_Address;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type SSE.Storage_Offset;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   Submission_Offset    : constant DMA.Byte_Count := 0;
   Completion_Offset    : constant DMA.Byte_Count := 4096;
   IO_Submission_Offset : constant DMA.Byte_Count := 8192;
   IO_Completion_Offset : constant DMA.Byte_Count := 12288;
   Buffer_Offset        : constant DMA.Byte_Count := 16384;
   Scratch_Bytes        : constant := 20480;

   Queue_Entries : constant Positive := 16;
   IO_Queue      : constant Controller.Queue_Identifier := 1;

   --  Which vector the completion queue is bound to. Deliberately not
   --  vector zero: a driver that ignored the vector field entirely, or an
   --  interrupt request whose tail arithmetic was wrong by one entry, would
   --  deliver on zero and pass a test that only ever used zero.
   Chosen_Vector : constant := 2;

   --  How many to enable. More than one is the whole point, and more than
   --  the chosen vector so that delivery on the wrong one is detectable.
   Vectors_Wanted : constant := 4;
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
         Available : constant IRQ.Interrupt_Details :=
           IRQ.Describe (Device, IRQ.MSI_X);
      begin
         if not Available.Implemented
           or else Available.Count < Vectors_Wanted
         then
            Harness.Skip
              ("every MSI-X check",
               "this device offers" & Natural'Image (Available.Count)
               & " vector(s) and" & Natural'Image (Vectors_Wanted)
               & " are needed");
            Harness.Report ("msix_tests");
            return;
         end if;

         Harness.Note
           ("the device offers" & Natural'Image (Available.Count)
            & " MSI-X vectors; enabling" & Natural'Image (Vectors_Wanted));
      end;

      declare
         --  One eventfd per vector. They are separate objects rather than
         --  an array because an Event is limited and finalizes itself.
         Vector_0 : IRQ.Event;
         Vector_1 : IRQ.Event;
         Vector_2 : IRQ.Event;
         Vector_3 : IRQ.Event;

         Waiting : IRQ.Blocking_Waiter;
      begin
         IRQ.Open (Vector_0);
         IRQ.Open (Vector_1);
         IRQ.Open (Vector_2);
         IRQ.Open (Vector_3);

         declare
            Descriptors : constant IRQ.Vector_Descriptors :=
              [0 => IRQ.Descriptor (Vector_0),
               1 => IRQ.Descriptor (Vector_1),
               2 => IRQ.Descriptor (Vector_2),
               3 => IRQ.Descriptor (Vector_3)];

            Watched : constant IRQ.Descriptor_Array :=
              [1 => IRQ.Descriptor (Vector_0),
               2 => IRQ.Descriptor (Vector_1),
               3 => IRQ.Descriptor (Vector_2),
               4 => IRQ.Descriptor (Vector_3)];
         begin
            IRQ.Enable (Device, IRQ.MSI_X, Descriptors);
            Harness.Check
              (True,
               "four MSI-X vectors were enabled in one request, whose"
               & " length the kernel checks against the vector count");

            --  Nothing should be pending before the device is asked to do
            --  anything. A waiter that returned immediately here would make
            --  every check below meaningless.
            Harness.Check
              (Waiting.Wait_For_Any (Watched, Timeout => 0.05) = 0,
               "no vector is pending before the device has been given work");

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

                     Admin_Sub : constant Controller.Queue_Location :=
                       (Kind    => Controller.Admin,
                        Host    =>
                          Host + SSE.Storage_Offset (Submission_Offset),
                        Device  =>
                          Window_Base + Device_Address (Submission_Offset),
                        Entries => Queue_Entries);
                     Admin_Comp : constant Controller.Queue_Location :=
                       (Kind    => Controller.Admin,
                        Host    =>
                          Host + SSE.Storage_Offset (Completion_Offset),
                        Device  =>
                          Window_Base + Device_Address (Completion_Offset),
                        Entries => Queue_Entries);
                     IO_Sub : constant Controller.Queue_Location :=
                       (Kind    => Controller.Namespace_IO,
                        Host    =>
                          Host + SSE.Storage_Offset (IO_Submission_Offset),
                        Device  =>
                          Window_Base + Device_Address (IO_Submission_Offset),
                        Entries => Queue_Entries);
                     IO_Comp : constant Controller.Queue_Location :=
                       (Kind    => Controller.Namespace_IO,
                        Host    =>
                          Host + SSE.Storage_Offset (IO_Completion_Offset),
                        Device  =>
                          Window_Base + Device_Address (IO_Completion_Offset),
                        Entries => Queue_Entries);
                     Buffer_Device : constant Device_Address :=
                       Window_Base + Device_Address (Buffer_Offset);

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
                  begin
                     Everything := (others => 0);
                     Controller.Disable (BAR);
                     Controller.Enable (BAR, Admin_Sub, Admin_Comp);

                     --  A completion queue bound to one chosen vector. The
                     --  controller signals that vector, and only that one,
                     --  when it posts into this queue.
                     Controller.Write_Create_Completion_Queue_Command
                       (Admin_Sub, Admin_Slot, Next_ID, IO_Queue,
                        Queue_Entries, IO_Comp.Device,
                        Interrupt_Vector => Chosen_Vector);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "a completion queue bound to vector"
                        & Integer'Image (Chosen_Vector) & " was created");

                     Controller.Write_Create_Submission_Queue_Command
                       (Admin_Sub, Admin_Slot, Next_ID, IO_Queue, IO_Queue,
                        Queue_Entries, IO_Sub.Device);
                     Harness.Check_Equal
                       (U32 (Run_Admin.Status), 0,
                        "and a submission queue reporting into it");

                     --  The admin queue signals vector zero, always: it is
                     --  created when the controller is enabled and its
                     --  vector is fixed at zero by the specification. So
                     --  the two commands above have already left signals
                     --  pending there, and a test that did not drain them
                     --  would see vector zero fire and conclude the
                     --  binding had been ignored.
                     --
                     --  This is not a quirk of the emulator. It is why a
                     --  real driver gives its admin queue a vector of its
                     --  own and does not share it with an I/O queue.
                     --  Drained until it goes quiet rather than taken
                     --  once. A completion and its interrupt are separate
                     --  events: the loop above finished when it saw the
                     --  entry in memory, so one Take collects what had
                     --  arrived by then and leaves the last one in flight,
                     --  to be mistaken later for a signal from the I/O
                     --  queue.
                     declare
                        From_Admin : Interfaces.Unsigned_64 := 0;
                     begin
                        while Waiting.Wait_For (Vector_0, 0.05) loop
                           From_Admin := From_Admin + IRQ.Take (Vector_0);
                        end loop;
                        Harness.Check
                          (From_Admin > 0,
                           "the admin queue signalled vector zero while it"
                           & " was being set up, which is where those"
                           & " completions were announced");
                     end;
                     Harness.Check
                       (IRQ.Take (Vector_1) = 0
                          and then IRQ.Take (Vector_2) = 0
                          and then IRQ.Take (Vector_3) = 0,
                        "and nothing else had been signalled yet");

                     --  Submit, then wait. No polling of the completion
                     --  queue: if the interrupt does not arrive, this fails
                     --  rather than quietly succeeding by other means.
                     Controller.Write_Block_Command
                       (IO_Sub, 0, Next_ID, Controller.Opcode_Read, 1, 0, 1,
                        Buffer_Device);
                     Controller.Ring_Submission_Doorbell
                       (BAR, Stride, IO_Queue, 1);

                     declare
                        Ready : constant Natural :=
                          Waiting.Wait_For_Any (Watched, Timeout => 5.0);
                     begin
                        Harness.Check
                          (Ready /= 0,
                           "an interrupt arrived rather than the wait"
                           & " timing out, so the device signalled and the"
                           & " kernel delivered it to an eventfd");
                        Harness.Check
                          (Ready = Chosen_Vector + 1,
                           "it arrived on vector"
                           & Integer'Image (Chosen_Vector)
                           & ", the one the queue was bound to, rather than"
                           & " on vector zero — which is what a request"
                           & " whose tail was built wrong would have done"
                           & " (it arrived on index"
                           & Natural'Image (Ready) & ")");
                     end;

                     --  The count an eventfd carries is how many times the
                     --  kernel signalled since it was last drained.
                     Harness.Check
                       (IRQ.Take (Vector_2) > 0,
                        "the chosen vector's descriptor carries a count");
                     Harness.Check
                       (IRQ.Take (Vector_0) = 0
                          and then IRQ.Take (Vector_1) = 0
                          and then IRQ.Take (Vector_3) = 0,
                        "and no other vector was signalled by the I/O"
                        & " command, so the vector field in the queue"
                        & " creation was honoured rather than ignored");

                     --  The completion really is there, which proves the
                     --  interrupt was not merely noise.
                     declare
                        Answer : constant Controller.Completion :=
                          Controller.Read_Completion (IO_Comp, 0);
                     begin
                        Harness.Check
                          (Answer.Phase,
                           "the completion the interrupt announced is in"
                           & " the queue");
                        Harness.Check_Equal
                          (U32 (Answer.Status), 0,
                           "and it reports the read succeeded");
                     end;

                     Controller.Ring_Completion_Doorbell
                       (BAR, Stride, IO_Queue, 1);

                     --  A second command, to show delivery is repeatable
                     --  rather than a one-off left over from setup.
                     Controller.Write_Block_Command
                       (IO_Sub, 1, Next_ID, Controller.Opcode_Read, 1, 8, 1,
                        Buffer_Device);
                     Controller.Ring_Submission_Doorbell
                       (BAR, Stride, IO_Queue, 2);

                     Harness.Check
                       (Waiting.Wait_For (Vector_2, Timeout => 5.0),
                        "a second command interrupts on the same vector,"
                        & " so delivery is armed continuously rather than"
                        & " once");

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

   Harness.Report ("msix_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every MSI-X check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("msix_tests");
end MSIX_Tests;
