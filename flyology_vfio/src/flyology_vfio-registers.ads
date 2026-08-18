with Flyology_DMA;
use type Flyology_DMA.Byte_Count;
with Flyology_VFIO.Regions;
with Interfaces;

--  Memory-mapped register access, with the ordering already decided.
--
--  Ordering is this crate's responsibility, not the caller's. A driver that
--  had to reason about barriers at every doorbell would get it wrong
--  somewhere, and the symptom — a device that occasionally reads a
--  descriptor the CPU had not finished writing — appears far from the
--  omission and only under load. So the primitives here come in ordered
--  pairs, and the memory model is part of each operation's name.
--
--  Why not Ada's own Atomic: Ada 2022 requires atomic objects to be
--  sequentially consistent, with no way to ask for acquire or release. That
--  is both stronger than a doorbell needs and the wrong shape, so the
--  ordered accessors below are built on the compiler's atomic builtins,
--  each called with a memory model fixed at the call site. The model is
--  never a parameter: GCC silently falls back to the strongest ordering
--  when it is not a compile-time constant, so a model passed as a variable
--  would compile, run correctly, and quietly cost what it was meant to save.
--
--  Widths: 32-bit and 64-bit accesses are what a device specification
--  normally calls for, and are what a caller should reach for first. The
--  8-bit and 16-bit accessors exist because some real devices do specify
--  narrow registers, and a driver forced to work around their absence would
--  hand-roll something worse. Nothing here accesses a register in pieces:
--  every operation is a single whole-width load or store, which is what
--  Volatile_Full_Access guarantees and what MMIO requires. To change part of
--  a register, read the whole of it, mask in Ada, and write the whole of it
--  back — but see the note on Read_Modify_Write hazards below.
--
--  A caution the type system cannot express: a register that clears bits on
--  read, or that clears bits when a one is written to them, must not be
--  read-modify-written. The read half of the sequence acknowledges
--  something, and the write half puts back bits that arrived in between.
--  For those registers, write the whole value the specification calls for.
--
--  Mapping attributes: vfio-pci maps device regions uncacheable. It offers
--  no write-combining mapping at all — the write-combining mechanism some
--  drivers use through sysfs is a different interface, not this one — so no
--  code path in this crate can obtain one. That simplifies the ordering
--  story: on x86 the store ordering a doorbell needs comes for free, and on
--  arm64 a release store is what orders the descriptor writes that precede
--  it against the doorbell itself.
package Flyology_VFIO.Registers is

   --  A byte offset into a mapped region.
   subtype Offset is Flyology_DMA.Byte_Count;

   subtype U8 is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   --  Whether an access of the given width at the given offset lies inside
   --  the window and is naturally aligned.
   --
   --  Both halves matter. An access past the end reads whatever the kernel
   --  put after the mapping, and a misaligned MMIO access is undefined on
   --  the bus: it may be split into two transactions the device treats as
   --  two unrelated accesses, which is exactly the piecewise access this
   --  package exists to prevent.
   --
   --  @param Window_Length The window's extent in bytes
   --  @param At_Offset Where the access starts
   --  @param Width Bytes the access covers
   --  @return True when the access is in bounds and aligned
   function Is_Valid_Access
     (Window_Length : Offset; At_Offset : Offset; Width : Offset)
      return Boolean
   is (Width > 0
       and then At_Offset <= Window_Length - Width
       and then At_Offset mod Width = 0);

   ---------------------------------------------------------------------
   --  Plain accesses
   --
   --  Volatile and whole-width, with no ordering beyond what the machine
   --  gives. Use these for registers whose order relative to other memory
   --  does not matter: identification, capabilities, and configuration
   --  written before a device is started.
   ---------------------------------------------------------------------

   --  Reads a whole 32-bit register.
   --  @param From The mapped region
   --  @param At_Offset Byte offset within it
   --  @return The register's value
   function Read_32 (From : Regions.Window; At_Offset : Offset) return U32
     with Pre => Regions.Is_Mapped (From)
                 and then Is_Valid_Access
                            (Regions.Length (From), At_Offset, 4);

   --  Writes a whole 32-bit register.
   --  @param Into The mapped region
   --  @param At_Offset Byte offset within it
   --  @param Value The value to write
   procedure Write_32
     (Into : Regions.Window; At_Offset : Offset; Value : U32)
     with Pre => Regions.Is_Mapped (Into)
                 and then Is_Valid_Access
                            (Regions.Length (Into), At_Offset, 4);

   --  Reads a whole 64-bit register.
   --  @param From The mapped region
   --  @param At_Offset Byte offset within it
   --  @return The register's value
   function Read_64 (From : Regions.Window; At_Offset : Offset) return U64
     with Pre => Regions.Is_Mapped (From)
                 and then Is_Valid_Access
                            (Regions.Length (From), At_Offset, 8);

   --  Writes a whole 64-bit register.
   --  @param Into The mapped region
   --  @param At_Offset Byte offset within it
   --  @param Value The value to write
   procedure Write_64
     (Into : Regions.Window; At_Offset : Offset; Value : U64)
     with Pre => Regions.Is_Mapped (Into)
                 and then Is_Valid_Access
                            (Regions.Length (Into), At_Offset, 8);

   --  Reads a whole 16-bit register. Prefer a wider access unless a device
   --  specification calls for this one.
   --  @param From The mapped region
   --  @param At_Offset Byte offset within it
   --  @return The register's value
   function Read_16 (From : Regions.Window; At_Offset : Offset) return U16
     with Pre => Regions.Is_Mapped (From)
                 and then Is_Valid_Access
                            (Regions.Length (From), At_Offset, 2);

   --  Writes a whole 16-bit register.
   --  @param Into The mapped region
   --  @param At_Offset Byte offset within it
   --  @param Value The value to write
   procedure Write_16
     (Into : Regions.Window; At_Offset : Offset; Value : U16)
     with Pre => Regions.Is_Mapped (Into)
                 and then Is_Valid_Access
                            (Regions.Length (Into), At_Offset, 2);

   --  Reads a whole 8-bit register.
   --  @param From The mapped region
   --  @param At_Offset Byte offset within it
   --  @return The register's value
   function Read_8 (From : Regions.Window; At_Offset : Offset) return U8
     with Pre => Regions.Is_Mapped (From)
                 and then Is_Valid_Access
                            (Regions.Length (From), At_Offset, 1);

   --  Writes a whole 8-bit register.
   --  @param Into The mapped region
   --  @param At_Offset Byte offset within it
   --  @param Value The value to write
   procedure Write_8
     (Into : Regions.Window; At_Offset : Offset; Value : U8)
     with Pre => Regions.Is_Mapped (Into)
                 and then Is_Valid_Access
                            (Regions.Length (Into), At_Offset, 1);

   ---------------------------------------------------------------------
   --  Ordered accesses
   --
   --  These are the pair a driver actually needs. A release store makes
   --  every write the CPU issued before it visible before the store itself
   --  becomes visible, which is what a doorbell means: the descriptors are
   --  ready, now go. An acquire load makes everything the device wrote
   --  before setting a completion flag visible after the flag has been
   --  seen, which is what reading a completion means.
   ---------------------------------------------------------------------

   --  Reads a 32-bit register with acquire ordering.
   --
   --  Reads issued after this cannot be reordered before it. Use it for the
   --  register that tells you a device has finished something, so that the
   --  data it produced is visible once the flag has been seen.
   --
   --  @param From The mapped region
   --  @param At_Offset Byte offset within it
   --  @return The register's value
   function Read_Acquire_32
     (From : Regions.Window; At_Offset : Offset) return U32
     with Pre => Regions.Is_Mapped (From)
                 and then Is_Valid_Access
                            (Regions.Length (From), At_Offset, 4);

   --  Writes a 32-bit register with release ordering.
   --
   --  Writes issued before this cannot be reordered after it. This is the
   --  doorbell primitive: descriptors written first are visible to the
   --  device before it is told to look.
   --
   --  @param Into The mapped region
   --  @param At_Offset Byte offset within it
   --  @param Value The value to write
   procedure Write_Release_32
     (Into : Regions.Window; At_Offset : Offset; Value : U32)
     with Pre => Regions.Is_Mapped (Into)
                 and then Is_Valid_Access
                            (Regions.Length (Into), At_Offset, 4);

   --  Reads a 64-bit register with acquire ordering.
   --  @param From The mapped region
   --  @param At_Offset Byte offset within it
   --  @return The register's value
   function Read_Acquire_64
     (From : Regions.Window; At_Offset : Offset) return U64
     with Pre => Regions.Is_Mapped (From)
                 and then Is_Valid_Access
                            (Regions.Length (From), At_Offset, 8);

   --  Writes a 64-bit register with release ordering.
   --  @param Into The mapped region
   --  @param At_Offset Byte offset within it
   --  @param Value The value to write
   procedure Write_Release_64
     (Into : Regions.Window; At_Offset : Offset; Value : U64)
     with Pre => Regions.Is_Mapped (Into)
                 and then Is_Valid_Access
                            (Regions.Length (Into), At_Offset, 8);

   ---------------------------------------------------------------------
   --  Standalone barriers
   --
   --  For the cases the ordered accessors do not cover: ordering two plain
   --  register accesses against each other, or ordering ordinary memory
   --  against a register when the register access itself must stay plain.
   ---------------------------------------------------------------------

   --  Makes every earlier store visible before any later store.
   procedure Store_Fence;

   --  Makes every earlier load complete before any later load.
   procedure Load_Fence;

   --  Orders every earlier access against every later one.
   procedure Full_Fence;

end Flyology_VFIO.Registers;
