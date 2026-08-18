with System.Storage_Elements;

package body Flyology_DMA.Pools is

   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;

   package SSE renames System.Storage_Elements;

   --  Where the buffer with the given index starts, relative to the start of
   --  the mapping. One expression, used for both addresses, so the host and
   --  device views of a buffer cannot drift apart.
   function Displacement (Self : Pool; Index : Buffer_Index) return Byte_Count
   is (Self.Step * Byte_Count (Index - 1));

   ------------
   -- Offset --
   ------------

   function Offset
     (Handle : Buffer_Handle; By : Byte_Count) return Buffer_Handle
   is
     (Host   => Handle.Host + SSE.Storage_Offset (By),
      IOVA   => Handle.IOVA + IOVA_Address (By),
      Length => Handle.Length - By,
      Index  => Handle.Index);

   ---------------
   -- Configure --
   ---------------

   procedure Configure
     (Self        : in out Pool;
      Mapped      : Mappers.Mapping;
      Buffer_Size : Byte_Count;
      Align_To    : Alignment := 64)
   is
      Step   : constant Byte_Count := Align_Up (Buffer_Size, Align_To);
      Needed : constant Byte_Count := Step * Byte_Count (Self.Capacity);
   begin
      if not Mappers.Is_Live (Mapped) then
         raise Pool_Error with
           "a pool cannot be laid out over a mapping that has been released."
           & " Declare the pool after the mapping it uses, so the mapping"
           & " outlives it.";
      end if;

      if Needed > Mappers.Length (Mapped) then
         raise Pool_Error with
           "a pool of" & Buffer_Index'Image (Self.Capacity) & " buffers of"
           & Byte_Count'Image (Buffer_Size) & " bytes at a stride of"
           & Byte_Count'Image (Step) & " needs" & Byte_Count'Image (Needed)
           & " bytes, and the mapping holds"
           & Byte_Count'Image (Mappers.Length (Mapped))
           & ". Enlarge the region, reduce the buffer count, or reduce the"
           & " alignment.";
      end if;

      Self.Host   := Mappers.Host_Base (Mapped);
      Self.Device := Mappers.IOVA_Base (Mapped);
      Self.Usable := Buffer_Size;
      Self.Step   := Step;
      Free_Lists.Reset (Self.Slots);
      Self.Configured := True;
   end Configure;

   -------------
   -- Acquire --
   -------------

   procedure Acquire
     (Self      : in out Pool;
      Handle    : out Buffer_Handle;
      Succeeded : out Boolean)
   is
      Slot : Free_Lists.Slot_Index;
      Took : Boolean;
   begin
      Free_Lists.Take (Self.Slots, Slot, Took);
      if not Took then
         Handle := (Host   => System.Null_Address,
                    IOVA   => 0,
                    Length => 0,
                    Index  => 1);
         Succeeded := False;
         return;
      end if;

      declare
         Index : constant Buffer_Index := Slot;
         Where : constant Byte_Count := Displacement (Self, Index);
      begin
         Handle := (Host   => Self.Host + SSE.Storage_Offset (Where),
                    IOVA   => Self.Device + IOVA_Address (Where),
                    Length => Self.Usable,
                    Index  => Index);
      end;
      Succeeded := True;
   end Acquire;

   -------------
   -- Release --
   -------------

   procedure Release (Self : in out Pool; Handle : Buffer_Handle) is
      Slot : Buffer_Index;
   begin
      if Handle.Index > Self.Capacity then
         raise Pool_Error with
           "buffer index" & Buffer_Index'Image (Handle.Index)
           & " is outside this pool, which holds"
           & Buffer_Index'Image (Self.Capacity) & " buffers.";
      end if;

      --  A handle whose address does not match the slot it names came from
      --  somewhere else, or has been altered. Either way the free list must
      --  not accept it: releasing a foreign handle frees a buffer this pool
      --  believes is still in use.
      if Handle.Host
        /= Self.Host + SSE.Storage_Offset (Displacement (Self, Handle.Index))
      then
         raise Pool_Error with
           "the handle for buffer" & Buffer_Index'Image (Handle.Index)
           & " does not carry the address this pool gave that buffer. A"
           & " handle from another pool, or one taken from Offset of a"
           & " different buffer, cannot be released here.";
      end if;

      Slot := Handle.Index;

      if not Free_Lists.Is_Held (Self.Slots, Slot) then
         raise Pool_Error with
           "buffer" & Buffer_Index'Image (Handle.Index)
           & " is already free. Releasing a buffer twice would let the pool"
           & " hand the same bytes to two callers at once.";
      end if;

      Free_Lists.Give (Self.Slots, Slot);
   end Release;

   ---------------
   -- Available --
   ---------------

   function Available (Self : Pool) return Natural is
     (Natural (Free_Lists.Available (Self.Slots)));

end Flyology_DMA.Pools;
