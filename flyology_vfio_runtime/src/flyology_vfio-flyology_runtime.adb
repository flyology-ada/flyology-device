with Flyology.IO;

package body Flyology_VFIO.Flyology_Runtime is

   --  The runtime's timeout convention and this crate's agree: a negative
   --  duration means no limit. That is not a coincidence — Flyology_VFIO
   --  adopted poll's convention, and so did the runtime — but it is worth
   --  saying rather than leaving as a silent assumption.

   --------------
   -- Wait_For --
   --------------

   overriding function Wait_For
     (Self    : in out Runtime_Waiter;
      Signal  : Interrupts.Event'Class;
      Timeout : Duration) return Boolean
   is
      pragma Unreferenced (Self);
   begin
      return Flyology.IO.Wait
        (FD        => Flyology.IO.Descriptor (Interrupts.Descriptor (Signal)),
         Condition => Flyology.IO.For_Read,
         Timeout   => Timeout);
   exception
      when Flyology.IO.Device_Error =>
         raise Interrupt_Error with
           "waiting for an interrupt failed: the runtime reported the"
           & " descriptor invalid or its poller unusable";
   end Wait_For;

   ------------------
   -- Wait_For_Any --
   ------------------

   overriding function Wait_For_Any
     (Self    : in out Runtime_Waiter;
      Signals : Interrupts.Descriptor_Array;
      Timeout : Duration) return Natural
   is
      pragma Unreferenced (Self);
      Requests : Flyology.IO.Wait_Request_Array (Signals'Range);
   begin
      if Signals'Length = 0 then
         return 0;
      end if;

      if Signals'Length > Flyology.IO.Max_Wait_Requests then
         raise Interrupt_Error with
           "waiting on" & Natural'Image (Signals'Length)
           & " descriptors at once exceeds the runtime's limit of"
           & Natural'Image (Flyology.IO.Max_Wait_Requests)
           & ". Watching only some of them would stall the rest with"
           & " nothing to say why, so this is refused instead.";
      end if;

      for Index in Signals'Range loop
         Requests (Index) :=
           (FD        => Flyology.IO.Descriptor (Signals (Index)),
            Condition => Flyology.IO.For_Read);
      end loop;

      --  The runtime returns the caller's own index, and the lowest wins
      --  when several are ready at once — the same contract this crate's
      --  own waiter offers, so the two are interchangeable.
      return Flyology.IO.Wait_Any (Requests, Timeout);
   exception
      when Flyology.IO.Device_Error =>
         raise Interrupt_Error with
           "waiting for one of" & Natural'Image (Signals'Length)
           & " interrupts failed: the runtime reported a descriptor"
           & " invalid or its poller unusable";
   end Wait_For_Any;

   -----------------------
   -- Maximum_Watched --
   -----------------------

   function Maximum_Watched return Positive is
     (Flyology.IO.Max_Wait_Requests);

   ---------------------
   -- On_Event_Loop --
   ---------------------

   function On_Event_Loop return Boolean is
     (Flyology.IO.Is_Lightweight_Task);

end Flyology_VFIO.Flyology_Runtime;
