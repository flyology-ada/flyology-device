with Flyology_VFIO_QEMU;

--  What every device test in this crate needs: a tally, and a way to say
--  why a test could not run.
--
--  A device test that cannot find its device has not passed. It has also
--  not failed, because the absence is an environment problem rather than a
--  defect. Skips are counted and printed so that a run which checked
--  nothing cannot be mistaken for a run which checked everything.
package Harness is

   --  Records one passing or failing check.
   --  @param Condition What was expected to hold
   --  @param Label What the check is called in the output
   procedure Check (Condition : Boolean; Label : String);

   --  Records a check comparing two values, printing both when they differ.
   --  @param Actual What the device produced
   --  @param Expected What it should have produced
   --  @param Label What the check is called in the output
   procedure Check_Equal
     (Actual, Expected : Flyology_VFIO_QEMU.U32; Label : String);

   --  Records a check comparing two 64-bit values.
   --  @param Actual What the device produced
   --  @param Expected What it should have produced
   --  @param Label What the check is called in the output
   procedure Check_Equal
     (Actual, Expected : Flyology_VFIO_QEMU.U64; Label : String);

   --  Notes something the environment could not support.
   --  @param Label What was skipped
   --  @param Because Why it could not run
   procedure Skip (Label : String; Because : String);

   --  Prints a line of context that is neither a check nor a skip.
   --  @param Text What to say
   procedure Note (Text : String);

   --  Prints the tally and sets a failing exit status if anything failed.
   --  @param Program The test program's name
   procedure Report (Program : String);

end Harness;
