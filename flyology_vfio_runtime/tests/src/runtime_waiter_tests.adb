--  Waiting for a device interrupt from both kinds of Ada task.
--
--  The runtime distinguishes two lanes. A native task is an ordinary Ada
--  task on its own thread; a lightweight task runs on an event loop shared
--  with others. Flyology.IO.Wait serves both, deciding for itself which is
--  calling, and this checks that the waiter built on it really does work
--  either way — because a driver written against it will be used from both
--  and must not need to know which.
--
--  No device is involved. VFIO delivers an interrupt by making an eventfd
--  readable, and an eventfd can be made readable by writing to it, so the
--  waiter can be checked against exactly the thing it will see in service
--  without needing a controller to be present. That also means these tests
--  run anywhere, which the device tests deliberately do not.
--
--  What this does not prove is that a lightweight wait yields its event
--  loop to siblings rather than monopolising it. That is the runtime's
--  contract rather than this crate's, and demonstrating it would need a
--  test built around scheduling rather than around a device.

with Ada.Exceptions;
with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.Task_Scopes;
with Flyology_VFIO;
with Flyology_VFIO.Flyology_Runtime;
with Flyology_VFIO.Interrupts;
with Interfaces;
use type Interfaces.Unsigned_64;
with Runtime_Harness;

procedure Runtime_Waiter_Tests is
   use Flyology_VFIO;

   package Adapter renames Flyology_VFIO.Flyology_Runtime;
   package IRQ renames Flyology_VFIO.Interrupts;

   --  What a spawned operation is given: a descriptor to wait on and how
   --  long to wait. Deliberately small and copyable, because a task scope
   --  copies its input into fixed storage.
   type Wait_Input is record
      Signal  : Integer;
      Timeout : Duration;
   end record;

   --  What it reports back.
   type Wait_Result is record
      Arrived     : Boolean;
      Lightweight : Boolean;
   end record;

   procedure Wait_In_Task
     (Input    : Wait_Input;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Wait_Result);

   -------------------
   -- Wait_In_Task --
   -------------------

   procedure Wait_In_Task
     (Input    : Wait_Input;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Wait_Result)
   is
      pragma Unreferenced (Token, Deadline);
      Waiting : Adapter.Runtime_Waiter;
      Watched : constant IRQ.Descriptor_Array := [1 => Input.Signal];
   begin
      --  Asked from inside, where the answer should differ from the answer
      --  the main task gets.
      Result.Lightweight := Adapter.On_Event_Loop;
      Result.Arrived :=
        Waiting.Wait_For_Any (Watched, Input.Timeout) = 1;
   end Wait_In_Task;

   package Waiting_Scopes is
     new Flyology.Task_Scopes (Wait_Input, Wait_Result, Wait_In_Task);
begin
   Runtime_Harness.Note
     ("the main task reports itself "
      & (if Adapter.On_Event_Loop then "lightweight" else "native"));
   Runtime_Harness.Check
     (not Adapter.On_Event_Loop,
      "the main task is a native one, so the checks below cover both"
      & " lanes rather than one twice");
   Runtime_Harness.Check
     (Adapter.Maximum_Watched >= 8,
      "the runtime will watch at least eight descriptors in one call,"
      & " which is enough for a queue per vector");

   ------------------------------------------------------------------
   --  A descriptor that never becomes ready, in both lanes
   ------------------------------------------------------------------

   --  Timing out is the half of waiting that needs no device, and it is
   --  worth checking first: a waiter that returned immediately would make
   --  every later check pass for the wrong reason.
   declare
      Quiet   : IRQ.Event;
      Waiting : Adapter.Runtime_Waiter;
   begin
      IRQ.Open (Quiet);

      Runtime_Harness.Check
        (not Waiting.Wait_For (Quiet, Timeout => 0.05),
         "a native task waiting on a quiet descriptor times out rather"
         & " than reporting an arrival");

      declare
         Scope : Waiting_Scopes.Scope (Capacity => 1, Parent => null);
         Handle : Waiting_Scopes.Operation_Handle;
      begin
         Waiting_Scopes.Configure (Scope, Ada.Real_Time.Time_Last);
         Waiting_Scopes.Spawn
           (Scope, (Signal => IRQ.Descriptor (Quiet), Timeout => 0.05),
            Handle);
         Waiting_Scopes.Join (Scope);

         Runtime_Harness.Check
           (Waiting_Scopes.Succeeded (Scope, Handle),
            "a lightweight task can call the waiter at all");

         declare
            Outcome : constant Wait_Result :=
              Waiting_Scopes.Result (Scope, Handle);
         begin
            Runtime_Harness.Check
              (Outcome.Lightweight,
               "and it reports itself lightweight, so the two lanes really"
               & " are different and both have now been exercised");
            Runtime_Harness.Check
              (not Outcome.Arrived,
               "its wait on a quiet descriptor timed out too");
         end;
      end;
   end;

   ------------------------------------------------------------------
   --  A descriptor that does become ready, in both lanes
   ------------------------------------------------------------------

   --  An eventfd can be made readable without a device, by writing to it.
   --  That is exactly what the kernel does when a device interrupts, so a
   --  waiter that wakes for one wakes for the other; using it here keeps
   --  this test about the waiter rather than about a controller.
   declare
      Ready   : IRQ.Event;
      Waiting : Adapter.Runtime_Waiter;
   begin
      IRQ.Open (Ready);
      Runtime_Harness.Signal (IRQ.Descriptor (Ready));

      Runtime_Harness.Check
        (Waiting.Wait_For (Ready, Timeout => 2.0),
         "a native task wakes for a descriptor that is ready");
      Runtime_Harness.Check
        (IRQ.Take (Ready) > 0, "and the count it carried is recoverable");

      Runtime_Harness.Signal (IRQ.Descriptor (Ready));

      declare
         Scope : Waiting_Scopes.Scope (Capacity => 1, Parent => null);
         Handle : Waiting_Scopes.Operation_Handle;
      begin
         Waiting_Scopes.Configure (Scope, Ada.Real_Time.Time_Last);
         Waiting_Scopes.Spawn
           (Scope, (Signal => IRQ.Descriptor (Ready), Timeout => 2.0),
            Handle);
         Waiting_Scopes.Join (Scope);

         Runtime_Harness.Check
           (Waiting_Scopes.Succeeded (Scope, Handle)
              and then Waiting_Scopes.Result (Scope, Handle).Arrived,
            "and so does a lightweight task, through the same waiter and"
            & " the same call");
      end;
   end;

   ------------------------------------------------------------------
   --  Refusing what it cannot do
   ------------------------------------------------------------------

   declare
      Too_Many : constant IRQ.Descriptor_Array
        (1 .. Adapter.Maximum_Watched + 1) := [others => -1];
      Waiting  : Adapter.Runtime_Waiter;
      Refused  : Boolean := False;
   begin
      declare
         Ignored : constant Natural :=
           Waiting.Wait_For_Any (Too_Many, Timeout => 0.0);
      begin
         Runtime_Harness.Check (Ignored = 0, "unreachable");
      end;
   exception
      when Interrupt_Error =>
         Refused := True;
         Runtime_Harness.Check
           (Refused,
            "watching more descriptors than the runtime allows is refused"
            & " rather than silently watching a prefix, which would stall"
            & " the queues left out with nothing to say why");
   end;

   Runtime_Harness.Report ("runtime_waiter_tests");

exception
   when Error : others =>
      Runtime_Harness.Note
        ("unexpected: " & Ada.Exceptions.Exception_Name (Error) & ": "
         & Ada.Exceptions.Exception_Message (Error));
      Runtime_Harness.Check (False, "the run completed without raising");
      Runtime_Harness.Report ("runtime_waiter_tests");
end Runtime_Waiter_Tests;
