--  The check counters every test program in this crate shares.
package Support is

   --  Records one passing or failing check.
   --  @param Condition What was expected to hold
   --  @param Label What the check is called in the output
   procedure Check (Condition : Boolean; Label : String);

   --  Records that a call raised the exception it was supposed to.
   --  @param Raised Whether the expected exception was raised
   --  @param Label What the check is called in the output
   procedure Check_Raised (Raised : Boolean; Label : String);

   --  Notes something the host could not support, without failing.
   --
   --  Skips are counted and printed, so a run that checked almost nothing
   --  says so rather than looking like a run that checked everything.
   --
   --  @param Label What was skipped
   --  @param Because Why the host could not run it
   procedure Skip (Label : String; Because : String);

   --  Prints the tally and sets a failing exit status if anything failed.
   --  @param Program The test program's name
   procedure Report (Program : String);

end Support;
