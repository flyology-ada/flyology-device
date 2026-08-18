--  Exercises IOVA assignment.
--
--  The properties that matter are that an allocation lies wholly inside the
--  window it came from, that it is aligned as asked, and that two
--  allocations never overlap. An IOVA that runs past the end of its window
--  is a device write into memory nobody mapped, and nothing on the host
--  reports it.

with Flyology_DMA;
with Flyology_DMA.Address_Space;
with Support;

procedure Address_Space_Tests is
   use Flyology_DMA;
   package AS renames Flyology_DMA.Address_Space;
   use type AS.Assignment;

   Window_Base   : constant IOVA_Address := 16#1000_0000#;
   Window_Length : constant Byte_Count := 16 * 1024 * 1024;

   Space : AS.Allocator;
   First, Second, Third : IOVA_Address;
   Ok : Boolean;
begin
   AS.Configure_Window (Space, Window_Base, Window_Length, 4096);
   Support.Check (AS.Is_Configured (Space), "window is configured");
   Support.Check
     (AS.Strategy (Space) = AS.Bump_Window, "strategy is the bump window");
   Support.Check (AS.Used (Space) = 0, "a fresh window has nothing used");

   AS.Allocate (Space, 4096, 4096, 0, First, Ok);
   Support.Check (Ok, "the first allocation fits");
   Support.Check (First = Window_Base, "it starts at the window base");
   Support.Check (AS.Used (Space) = 4096, "it consumed one page");

   AS.Allocate (Space, 4096, 4096, 0, Second, Ok);
   Support.Check (Ok, "the second allocation fits");
   Support.Check
     (Second = Window_Base + 4096, "it follows the first without a gap");
   Support.Check
     (Second >= First + 4096, "allocations do not overlap");

   --  A larger alignment than the current position has to skip forward, and
   --  the skipped bytes must be counted as used or a later allocation will
   --  believe it has room it does not have.
   AS.Allocate (Space, 1024, 65536, 0, Third, Ok);
   Support.Check (Ok, "the aligned allocation fits");
   Support.Check
     (Third mod 65536 = 0, "it is aligned to the requested boundary");
   Support.Check
     (Third >= Second + 4096, "it starts past the previous allocation");
   Support.Check
     (AS.Used (Space) = Byte_Count (Third - Window_Base) + 1024,
      "padding is counted as used");

   --  Exhaustion is reported, not raised: a driver sizing its regions wants
   --  to hear about all of what did not fit.
   declare
      Big : IOVA_Address;
      Fit : Boolean;
   begin
      AS.Allocate (Space, Window_Length, 4096, 0, Big, Fit);
      Support.Check (not Fit, "an oversized request does not fit");
      Support.Check
        (AS.Used (Space) = Byte_Count (Third - Window_Base) + 1024,
         "a failed allocation consumes nothing");
   end;

   --  The window must be exhaustible exactly, with no off-by-one at the end.
   declare
      Tight : AS.Allocator;
      A, B  : IOVA_Address;
      Got_A, Got_B : Boolean;
   begin
      AS.Configure_Window (Tight, 0, 8192, 4096);
      AS.Allocate (Tight, 4096, 4096, 0, A, Got_A);
      AS.Allocate (Tight, 4096, 4096, 0, B, Got_B);
      Support.Check (Got_A and Got_B, "both pages of a two-page window fit");
      Support.Check (AS.Used (Tight) = 8192, "the window is exactly full");
      declare
         C : IOVA_Address;
         Got_C : Boolean;
      begin
         AS.Allocate (Tight, 1, 1, 0, C, Got_C);
         Support.Check (not Got_C, "a full window fits nothing more");
      end;
   end;

   --  Mirroring hands back the host address unchanged. It is the strategy
   --  that needs no window, and the one that is only meaningful where the
   --  IOMMU has been programmed to match or where nothing reads the IOVA.
   declare
      Mirror : AS.Allocator;
      Result : IOVA_Address;
      Got    : Boolean;
   begin
      AS.Configure_Mirror (Mirror);
      Support.Check
        (AS.Strategy (Mirror) = AS.Mirror_Host_Addresses,
         "strategy is mirroring");
      AS.Allocate (Mirror, 4096, 4096, 16#7F00_1234_5000#, Result, Got);
      Support.Check (Got, "mirroring always succeeds");
      Support.Check
        (Result = 16#7F00_1234_5000#, "the host value comes back unchanged");
   end;

   Support.Report ("address_space_tests");
end Address_Space_Tests;
