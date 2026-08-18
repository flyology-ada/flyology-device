--  The check counters every test program in this crate shares.
package Support is

   --  Records one passing or failing check.
   --  @param Condition What was expected to hold
   --  @param Label What the check is called in the output
   procedure Check (Condition : Boolean; Label : String);

   --  Records a check comparing two values, reporting both when they differ.
   --  @param Actual What was produced
   --  @param Expected What should have been produced
   --  @param Label What the check is called in the output
   procedure Check_Equal (Actual, Expected : String; Label : String);

   --  Records that a call raised the expected exception, or that it did not.
   --  @param Raised Whether the expected exception was raised
   --  @param Label What the check is called in the output
   procedure Check_Raised (Raised : Boolean; Label : String);

   --  Prints the tally and sets a failing exit status if anything failed.
   --  @param Program The test program's name, for the final line
   procedure Report (Program : String);

end Support;
