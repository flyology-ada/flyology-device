with Flyology_DMA.Free_Lists;
use type Flyology_DMA.Free_Lists.Slot_Index;
with Flyology_DMA.Mappers;
with System;

--  Fixed-size buffers carved from one mapped region.
--
--  The type that matters here is Buffer_Handle, because it carries both
--  addresses of the same bytes: the host virtual address a memcpy needs, and
--  the device-visible address a descriptor needs. Every driver needs both,
--  they are numerically unrelated, and writing one where the other belongs
--  is the defining bug of this problem domain. Carrying them together, in a
--  value that can only be produced by acquiring a buffer, is the whole point
--  of the type.
--
--  Concurrency: a pool has a single mutator. See Flyology_DMA.Free_Lists for
--  why that is stated rather than defended against.
--
--  Acquire and Release are constant-time and allocate nothing, because they
--  sit on a driver's per-packet path.
package Flyology_DMA.Pools is

   --  Identifies one buffer within its pool.
   --
   --  The same type as a free-list slot, so that a pool's capacity can
   --  constrain its free list directly. A distinct type would need a
   --  conversion in that constraint, which Ada does not allow.
   subtype Buffer_Index is Free_Lists.Slot_Index;

   --  One buffer, named by both addresses of the same bytes.
   --
   --  @field Host The host virtual address; what the CPU dereferences
   --  @field IOVA The device-visible address; what goes in a descriptor
   --  @field Length How many bytes the buffer holds
   --  @field Index Which slot of the pool it is, for constant-time release
   type Buffer_Handle is record
      Host   : System.Address;
      IOVA   : IOVA_Address;
      Length : Byte_Count;
      Index  : Buffer_Index;
   end record;

   --  A handle naming a later part of the same buffer.
   --
   --  Advances both addresses together and shrinks the length to match. It
   --  exists so that nothing ever advances one address without the other:
   --  a driver building a chained descriptor writes Offset (H, N) rather
   --  than adding N to two fields it has to remember to keep in step.
   --
   --  The result keeps the original Index, so releasing it releases the
   --  whole buffer, which is what a caller who split a buffer wants.
   --
   --  @param Handle The buffer to take an interior view of
   --  @param By How far into the buffer to start, in bytes
   --  @return A handle naming the remainder of the buffer
   function Offset
     (Handle : Buffer_Handle; By : Byte_Count) return Buffer_Handle
     with Pre  => By < Handle.Length,
          Post => Offset'Result.Length = Handle.Length - By
                  and then Offset'Result.Index = Handle.Index
                  and then Offset'Result.IOVA = Handle.IOVA + IOVA_Address (By);

   --  A fixed set of equally sized buffers cut from one mapped region.
   type Pool (Capacity : Buffer_Index) is limited private;

   --  Lays a pool out over a mapped region.
   --
   --  Buffers are placed end to end from the start of the mapping, each one
   --  starting at a multiple of Align_To. The region must be large enough
   --  for all of them; a pool that did not fit would either overlap its
   --  neighbours or run past the end of what the device is allowed to touch,
   --  so it is refused rather than truncated.
   --
   --  The default alignment is one cache line, which keeps two buffers in
   --  use by different parts of a driver off the same line.
   --
   --  @param Self The pool to lay out
   --  @param Mapped The mapping the buffers are cut from
   --  @param Buffer_Size Usable bytes in each buffer
   --  @param Align_To Alignment of each buffer's first byte
   --  @exception Pool_Error The mapping is too small for the geometry asked
   procedure Configure
     (Self        : in out Pool;
      Mapped      : Mappers.Mapping;
      Buffer_Size : Byte_Count;
      Align_To    : Alignment := 64)
     with Pre => Buffer_Size > 0 and then Is_Power_Of_Two (Align_To);

   --  Whether the pool has been laid out over a mapping.
   --  @param Self The pool
   --  @return True once Configure has run
   function Is_Configured (Self : Pool) return Boolean;

   --  Takes one buffer.
   --
   --  Reports exhaustion through Succeeded rather than raising: a driver
   --  that has run out of receive buffers drops a packet and carries on,
   --  and that path must not cost an exception.
   --
   --  @param Self The pool
   --  @param Handle The buffer taken, when Succeeded
   --  @param Succeeded False when every buffer is already out
   procedure Acquire
     (Self      : in out Pool;
      Handle    : out Buffer_Handle;
      Succeeded : out Boolean)
     with Pre => Is_Configured (Self);

   --  Returns one buffer.
   --
   --  The handle must be one this pool handed out and has not taken back.
   --  Both mistakes are refused by name rather than corrupting the free
   --  list, because a pool that hands the same buffer out twice puts two
   --  writers and a device on the same bytes with nothing to report it.
   --
   --  @param Self The pool
   --  @param Handle The buffer to return
   --  @exception Pool_Error The handle is foreign to this pool, or the
   --    buffer is already free
   procedure Release (Self : in out Pool; Handle : Buffer_Handle)
     with Pre => Is_Configured (Self);

   --  How many buffers are available to Acquire.
   --  @param Self The pool
   --  @return Count of free buffers
   function Available (Self : Pool) return Natural;

   --  The usable size of each buffer, in bytes.
   --  @param Self The pool
   --  @return Buffer size in bytes
   function Buffer_Size (Self : Pool) return Byte_Count
     with Pre => Is_Configured (Self);

   --  The distance between the starts of consecutive buffers, in bytes.
   --  @param Self The pool
   --  @return Stride in bytes, which is Buffer_Size rounded up to Align_To
   function Stride (Self : Pool) return Byte_Count
     with Pre => Is_Configured (Self);

private

   type Pool (Capacity : Buffer_Index) is limited record
      Configured : Boolean      := False;
      Host       : System.Address := System.Null_Address;
      Device     : IOVA_Address := 0;
      Usable     : Byte_Count   := 0;
      Step       : Byte_Count   := 0;
      Slots      : Free_Lists.Free_List (Capacity);
   end record;

   function Is_Configured (Self : Pool) return Boolean is (Self.Configured);
   function Buffer_Size (Self : Pool) return Byte_Count is (Self.Usable);
   function Stride (Self : Pool) return Byte_Count is (Self.Step);

end Flyology_DMA.Pools;
