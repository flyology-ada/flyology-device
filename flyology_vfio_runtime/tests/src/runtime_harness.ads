--  Check counters, and the one thing this crate's tests need that no
--  library here offers: making an eventfd readable on purpose.
package Runtime_Harness is

   --  Records one passing or failing check.
   --  @param Condition What was expected to hold
   --  @param Label What the check is called in the output
   procedure Check (Condition : Boolean; Label : String);

   --  Prints a line of context that is neither a check nor a skip.
   --  @param Text What to say
   procedure Note (Text : String);

   --  Makes an eventfd readable, as the kernel does when a device
   --  interrupts. Used so that the waiter can be tested without needing a
   --  device to be present.
   --  @param Descriptor The eventfd to signal
   procedure Signal (Descriptor : Integer);

   --  Prints the tally and sets a failing exit status if anything failed.
   --  @param Program The test program's name
   procedure Report (Program : String);

end Runtime_Harness;
