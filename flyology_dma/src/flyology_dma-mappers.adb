package body Flyology_DMA.Mappers is


   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Mapper) is
   begin
      if Self.Live /= 0 then
         --  A Mapping outliving its mapper would call Unmap on a finalized
         --  object. Failing loudly here names the scope that got the
         --  declaration order wrong; the alternative is a corruption whose
         --  cause is nowhere near its symptom.
         raise Program_Error with
           "a mapper was finalized while" & Natural'Image (Self.Live)
           & " of its mappings were still live. Declare each Mapping after"
           & " the mapper it uses, so it is finalized first.";
      end if;
   end Finalize;

   ----------------
   -- Map_Region --
   ----------------

   function Map_Region
     (Through   : not null access Mapper'Class;
      Subject   : Regions.Region;
      IOVA      : IOVA_Address;
      Direction : Device_Access := Device_Reads_And_Writes) return Mapping
   is
      Host   : constant System.Address := Regions.Base_Address (Subject);
      Extent : constant Byte_Count := Regions.Length (Subject);
   begin
      Through.Map (Host, Extent, IOVA, Direction);
      Through.Live := Through.Live + 1;

      return Result : Mapping do
         Result.Through   := Through.all'Unchecked_Access;
         Result.Host      := Host;
         Result.Device    := IOVA;
         Result.Extent    := Extent;
         Result.Direction := Direction;
         Result.Active    := True;
      end return;
   end Map_Region;

   -------------
   -- Release --
   -------------

   procedure Release (Self : in out Mapping) is
   begin
      if not Self.Active then
         return;
      end if;

      --  Mark inactive before unmapping. If Unmap raises, the mapping is
      --  gone as far as this object is concerned, and finalization must not
      --  try again with the same arguments.
      Self.Active := False;
      Self.Through.Live := Self.Through.Live - 1;
      Self.Through.Unmap (Self.Device, Self.Extent);
   end Release;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Mapping) is
   begin
      Release (Self);
   end Finalize;

   ---------
   -- Map --
   ---------

   overriding procedure Map
     (Self      : in out Identity_Mapper;
      Host_Base : System.Address;
      Length    : Byte_Count;
      IOVA      : IOVA_Address;
      Direction : Device_Access)
   is
   begin
      for Slot of Self.Entries loop
         if not Slot.In_Use then
            Slot := (In_Use    => True,
                     Host      => Host_Base,
                     Device    => IOVA,
                     Extent    => Length,
                     Direction => Direction);
            return;
         end if;
      end loop;

      raise Mapping_Error with
        "an Identity_Mapper records at most"
        & Integer'Image (Identity_Mapper_Capacity)
        & " simultaneous mappings and all of them are in use. It is a test"
        & " mapper; a test needing more is testing something else.";
   end Map;

   -----------
   -- Unmap --
   -----------

   overriding procedure Unmap
     (Self   : in out Identity_Mapper;
      IOVA   : IOVA_Address;
      Length : Byte_Count)
   is
   begin
      for Slot of Self.Entries loop
         if Slot.In_Use and then Slot.Device = IOVA then
            if Slot.Extent /= Length then
               raise Mapping_Error with
                 "unmap of" & Byte_Count'Image (Length) & " bytes at IOVA"
                 & IOVA_Address'Image (IOVA) & " does not match the mapping"
                 & " of" & Byte_Count'Image (Slot.Extent)
                 & " bytes established there. Unmap must match Map exactly.";
            end if;
            Slot.In_Use := False;
            return;
         end if;
      end loop;

      raise Mapping_Error with
        "no mapping starts at IOVA" & IOVA_Address'Image (IOVA);
   end Unmap;

   -------------------------
   -- Recorded_Direction --
   -------------------------

   function Recorded_Direction
     (Self : Identity_Mapper; IOVA : IOVA_Address) return Device_Access is
   begin
      for Slot of Self.Entries loop
         if Slot.In_Use and then Slot.Device = IOVA then
            return Slot.Direction;
         end if;
      end loop;

      raise Mapping_Error with
        "no mapping starts at IOVA" & IOVA_Address'Image (IOVA);
   end Recorded_Direction;

end Flyology_DMA.Mappers;
