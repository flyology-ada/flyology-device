with Flyology_VFIO.Interrupts;

--  Waiting for a device interrupt on a Flyology event loop.
--
--  Flyology_VFIO declares what waiting is and ships a waiter that blocks
--  the calling thread, because a crate at that level cannot decide how a
--  program spends its time. This is the other answer: a waiter that hands
--  the question to the Flyology runtime, which already knows how to watch a
--  descriptor.
--
--  It is a child of Flyology_VFIO and lives in a crate of its own so that
--  the dependency points the right way. The runtime brings a licence and a
--  custom Ada runtime with it, and neither belongs in a crate whose job is
--  to bind an ioctl. Anything that wants both takes this crate; anything
--  that does not is unaffected.
--
--  The reason it is worth having is not only ergonomics. Flyology.IO.Wait
--  decides for itself which kind of task is calling: a lightweight task
--  suspends on its event loop and its siblings keep running, while a native
--  task blocks its thread in poll. One waiter therefore serves both lanes,
--  and a driver written against it does not need to know which it is in.
--  It also carries a single deadline across interrupted waits, which the
--  Blocking_Waiter in Flyology_VFIO does not.
package Flyology_VFIO.Flyology_Runtime is

   package Interrupts renames Flyology_VFIO.Interrupts;

   --  Waits by asking the runtime, rather than by blocking a thread.
   --
   --  Holds no state: VFIO has already reduced an interrupt to a readable
   --  descriptor, and the runtime already knows how to wait for one of
   --  those, so there is nothing left for this type to carry.
   type Runtime_Waiter is limited new Interrupts.Waiter with null record;

   --  Waits for one device to interrupt.
   --
   --  A lightweight task suspends and yields its event loop; a native task
   --  blocks its own thread. Which of the two happens is the runtime's
   --  decision, not this crate's.
   --
   --  @param Self The waiter
   --  @param Signal The event the interrupt is delivered on
   --  @param Timeout How long to wait; negative means no limit
   --  @return True when the interrupt arrived, False on timeout
   --  @exception Interrupt_Error The wait itself failed
   overriding function Wait_For
     (Self    : in out Runtime_Waiter;
      Signal  : Interrupts.Event'Class;
      Timeout : Duration) return Boolean;

   --  Waits for any of several descriptors.
   --
   --  The runtime performs this without allocating, up to a limit it
   --  publishes as Flyology.IO.Max_Wait_Requests. Beyond that it raises
   --  rather than silently watching a prefix, because a driver that
   --  believed it was watching eight queues and was watching four would
   --  stall on the other four with nothing to say why.
   --
   --  @param Self The waiter
   --  @param Signals The descriptors to watch
   --  @param Timeout How long to wait; negative means no limit
   --  @return The index that became ready, or zero on timeout
   --  @exception Interrupt_Error The wait failed, or there are too many
   --    descriptors for one call
   overriding function Wait_For_Any
     (Self    : in out Runtime_Waiter;
      Signals : Interrupts.Descriptor_Array;
      Timeout : Duration) return Natural;

   --  The most descriptors one Wait_For_Any call may watch.
   --  @return The runtime's own limit
   function Maximum_Watched return Positive;

   --  Whether the calling task is a lightweight one.
   --
   --  Worth asking because it is the difference between a wait that yields
   --  and a wait that blocks a thread, which decides whether a driver
   --  should poll for a while before sleeping.
   --
   --  @return True for a lightweight task, False for a native one
   function On_Event_Loop return Boolean;

end Flyology_VFIO.Flyology_Runtime;
