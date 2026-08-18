--  What the host can currently support, reported rather than changed.
--
--  Every interesting failure in this crate is environmental: no hugepages
--  reserved, a memory-lock limit too low, a kernel built without hugetlbfs.
--  This package answers those questions so a program can say what is wrong
--  before it fails, and so a readiness script can report a host's state
--  without touching it.
--
--  Nothing here mutates the host. Reserving hugepages and raising limits are
--  decisions for whoever owns the machine, and a library that quietly made
--  them would be changing a global resource on behalf of a process that only
--  wanted to know.
package Flyology_DMA.Environment is

   --  What the host offers for one kind of region backing.
   --
   --  @field Supported Whether a region with this backing can be created here
   --  @field Page_Size The size of one page of this backing, in bytes
   --  @field Pages_Total Pages the kernel has reserved; zero where the notion
   --    does not apply
   --  @field Pages_Free Pages currently unused of those reserved
   type Backing_Report is record
      Supported   : Boolean;
      Page_Size   : Byte_Count;
      Pages_Total : Natural;
      Pages_Free  : Natural;
   end record;

   --  Reports what the host offers for one backing.
   --  @param Backing The backing to report on
   --  @return The host's current state for that backing
   function Report (Backing : Region_Backing) return Backing_Report;

   --  The process limit on locked memory, in bytes.
   --
   --  Worth checking even though this crate does not lock by default: a
   --  mapper pins the memory it maps, and that pin is charged against the
   --  same limit. A low limit shows up as a failure to map, not a failure to
   --  allocate.
   --
   --  @return The soft RLIMIT_MEMLOCK, or Byte_Count'Last when unlimited
   function Memory_Lock_Limit return Byte_Count;

   --  A human-readable summary of everything above.
   --
   --  Written for a person reading a script's output, so it names what is
   --  missing and the command that would provide it rather than only
   --  reporting numbers.
   --
   --  @return A multi-line report, each line terminated by a line feed
   function Summary return String;

end Flyology_DMA.Environment;
