package body Flyology_DMA.Free_Lists
  with SPARK_Mode => On
is

   -----------
   -- Reset --
   -----------

   procedure Reset (Self : in out Free_List) is
   begin
      --  Filled in descending order so that Take, which pops the top,
      --  hands out slot one first. A pool laid out over a region then
      --  allocates its buffers front to back on first use, which is the
      --  order a driver filling a receive ring expects and the order that
      --  touches pages in sequence.
      for S in 1 .. Self.Capacity loop
         Self.Stack (S) := Self.Capacity + 1 - S;
         Self.Held (S)  := False;
         pragma Loop_Invariant
           (for all T in 1 .. S =>
              Self.Stack (T) = Self.Capacity + 1 - T
              and then not Self.Held (T));
      end loop;
      Self.Count := Self.Capacity;
   end Reset;

   ----------
   -- Take --
   ----------

   procedure Take
     (Self      : in out Free_List;
      Slot      : out Slot_Index;
      Succeeded : out Boolean)
   is
   begin
      if Self.Count = 0 then
         Slot := 1;
         Succeeded := False;
         return;
      end if;

      Slot := Self.Stack (Self.Count);
      Self.Count := Self.Count - 1;
      Self.Held (Slot) := True;
      Succeeded := True;
   end Take;

   ----------
   -- Give --
   ----------

   procedure Give (Self : in out Free_List; Slot : Slot_Index) is
   begin
      Self.Count := Self.Count + 1;
      Self.Stack (Self.Count) := Slot;
      Self.Held (Slot) := False;
   end Give;

end Flyology_DMA.Free_Lists;
