with Flyology_DMA.Thin;

package body Flyology_DMA.Regions is

   use type System.Address;

   ------------
   -- Create --
   ------------

   function Create
     (Length  : Byte_Count;
      Backing : Region_Backing;
      Lock    : Boolean := False) return Region
   is
      Page    : constant Byte_Count := Thin.Page_Size (Backing);
      Rounded : constant Byte_Count := Align_Up (Length, Alignment (Page));
   begin
      --  Map_Anonymous is the one place that decides whether a backing is
      --  available here, and the one place that says what to do about it.
      return Result : Region do
         Result.Base   := Thin.Map_Anonymous (Rounded, Backing, Lock);
         Result.Extent := Rounded;
         Result.Kind   := Backing;
         Result.Page   := Page;
      end return;
   end Create;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Region) is
   begin
      if Self.Base /= System.Null_Address and then Self.Extent > 0 then
         declare
            Base   : constant System.Address := Self.Base;
            Extent : constant Byte_Count := Self.Extent;
         begin
            --  Clear first: if Unmap raises, a second finalization must not
            --  unmap the same range again.
            Self.Base := System.Null_Address;
            Self.Extent := 0;
            Thin.Unmap (Base, Extent);
         end;
      end if;
   end Finalize;

end Flyology_DMA.Regions;
