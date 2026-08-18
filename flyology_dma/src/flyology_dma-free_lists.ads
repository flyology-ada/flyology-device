--  The slot bookkeeping behind a buffer pool.
--
--  Separated from Flyology_DMA.Pools so that the part where an off-by-one
--  silently corrupts host memory is small, holds no addresses, and can be
--  proved. A pool hands a device the address of a buffer; if two acquires
--  ever return the same slot, two parts of a driver write to one buffer
--  while a device reads it, and nothing reports the collision. This unit is
--  where that cannot happen.
--
--  Every operation is constant-time and allocates nothing, because pools sit
--  on the per-packet path of a driver.
--
--  Concurrency: none. A free list has a single mutator. Two tasks calling
--  Take concurrently will hand out the same slot twice. This is stated
--  rather than defended against because a driver whose receive and transmit
--  paths are one task needs no synchronisation, and adding it speculatively
--  would cost every such driver. A cross-task pool is a different type, to
--  be written when a driver actually needs one.
package Flyology_DMA.Free_Lists
  with SPARK_Mode => On
is

   --  Take's postcondition compares availability against the entry state
   --  inside a conditional, which makes those 'Old prefixes potentially
   --  unevaluated. Evaluating them eagerly is safe: Available and
   --  Capacity_Of are total.
   pragma Unevaluated_Use_Of_Old (Allow);

   --  Identifies one slot of a free list. Slots are numbered from one.
   type Slot_Index is range 1 .. 2 ** 31 - 1;

   --  A count of slots, which unlike an index may be zero.
   --
   --  Every free list starts out with all slots free and, once emptied, has
   --  none. Both ends have to be expressible, and converting a zero count to
   --  Slot_Index would fail its range check on exactly the state a list is
   --  in when it is exhausted.
   subtype Slot_Count is Slot_Index'Base range 0 .. Slot_Index'Last;

   --  A fixed set of slots, each either held by a caller or free.
   type Free_List (Capacity : Slot_Index) is limited private;

   --  How many slots this list has in total.
   --  @param Self The free list
   --  @return The capacity it was declared with
   function Capacity_Of (Self : Free_List) return Slot_Index;

   --  How many slots are free.
   --  @param Self The free list
   --  @return Count of slots Take could still hand out
   function Available (Self : Free_List) return Slot_Count
     with Post => Available'Result <= Capacity_Of (Self);

   --  Whether a slot is currently held by a caller.
   --  @param Self The free list
   --  @param Slot The slot to ask about
   --  @return True when Take handed it out and Give has not taken it back
   function Is_Held (Self : Free_List; Slot : Slot_Index) return Boolean
     with Pre => Slot <= Capacity_Of (Self);

   --  Returns every slot to the free state.
   --
   --  A newly declared list holds all of its slots, so this is what makes
   --  one usable rather than what recovers one.
   --
   --  @param Self The free list to reset
   procedure Reset (Self : in out Free_List)
     with
       Post =>
         Capacity_Of (Self) = Capacity_Of (Self)'Old
         and then Available (Self) = Capacity_Of (Self)
         and then (for all S in 1 .. Capacity_Of (Self) =>
                     not Is_Held (Self, S));

   --  Takes one free slot.
   --  @param Self The free list
   --  @param Slot The slot taken, when Succeeded
   --  @param Succeeded False when no slot was free
   procedure Take
     (Self      : in out Free_List;
      Slot      : out Slot_Index;
      Succeeded : out Boolean)
     with
       Post =>
         Capacity_Of (Self) = Capacity_Of (Self)'Old
         and then Succeeded = (Available (Self)'Old > 0)
         and then
           (if Succeeded
            then Slot <= Capacity_Of (Self)
                 and then Is_Held (Self, Slot)
                 and then Available (Self) = Available (Self)'Old - 1
            else Available (Self) = Available (Self)'Old);

   --  Returns one held slot to the free state.
   --
   --  The slot must be held. Returning a slot twice is the corruption this
   --  unit exists to prevent, so callers ask Is_Held first and report the
   --  mistake in their own terms rather than relying on a check here.
   --
   --  @param Self The free list
   --  @param Slot The slot to return
   procedure Give (Self : in out Free_List; Slot : Slot_Index)
     with
       Pre  => Slot <= Capacity_Of (Self) and then Is_Held (Self, Slot),
       Post =>
         Capacity_Of (Self) = Capacity_Of (Self)'Old
         and then not Is_Held (Self, Slot)
         and then Available (Self) = Available (Self)'Old + 1;

private

   type Slot_Array is array (Slot_Index range <>) of Slot_Index;
   type Held_Array is array (Slot_Index range <>) of Boolean;

   type Free_List (Capacity : Slot_Index) is limited record
      --  Free slots, in Stack (1 .. Count). Kept as a stack rather than a
      --  linked list so that Take and Give touch one cache line each, and so
      --  that the invariants below are expressible at all.
      Stack : Slot_Array (1 .. Capacity) := (others => 1);
      --  A list that has not been Reset holds every slot, rather than
      --  offering every slot. The invariant below says that a slot which is
      --  not held is somewhere on the free stack, and an empty stack cannot
      --  satisfy that for a slot marked free. Starting held rather than free
      --  makes the default state consistent, and has the useful consequence
      --  that a list nobody reset hands out nothing rather than handing out
      --  slots whose bookkeeping was never initialised.
      Held  : Held_Array (1 .. Capacity) := (others => True);
      Count : Slot_Count                 := 0;
   end record
     with Ghost_Predicate =>
       Count <= Capacity
       --  Nothing on the free stack is simultaneously held.
       and then
         (for all I in Slot_Count range 1 .. Count => not Held (Stack (I)))
       --  No slot appears on the free stack twice, so two Takes can never
       --  return the same slot.
       and then
         (for all I in Slot_Count range 1 .. Count =>
            (for all J in Slot_Count range 1 .. Count =>
               (if I /= J then Stack (I) /= Stack (J))))
       --  Every slot is accounted for: held, or somewhere on the stack.
       and then
         (for all S in 1 .. Capacity =>
            (if not Held (S)
             then (for some I in Slot_Count range 1 .. Count =>
                     Stack (I) = S)));

   function Capacity_Of (Self : Free_List) return Slot_Index is
     (Self.Capacity);

   function Available (Self : Free_List) return Slot_Count is (Self.Count);

   function Is_Held (Self : Free_List; Slot : Slot_Index) return Boolean is
     (Self.Held (Slot));

end Flyology_DMA.Free_Lists;
