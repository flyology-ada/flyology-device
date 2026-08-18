package body Flyology_DMA.Address_Space
  with SPARK_Mode => On
is

   ----------------------
   -- Configure_Window --
   ----------------------

   procedure Configure_Window
     (Self        : out Allocator;
      Base        : IOVA_Address;
      Length      : Byte_Count;
      Granularity : Alignment)
   is
      pragma Unreferenced (Granularity);
   begin
      --  Granularity constrains the caller through the preconditions rather
      --  than being stored: base and length are already whole multiples of
      --  it, so every address handed out is too, and keeping a second copy
      --  of a constraint that has already been enforced only invites the two
      --  to disagree.
      Self.Configured := True;
      Self.Approach   := Bump_Window;
      Self.Base       := Base;
      Self.Extent     := Length;
      Self.Consumed   := 0;
   end Configure_Window;

   ----------------------
   -- Configure_Mirror --
   ----------------------

   procedure Configure_Mirror (Self : out Allocator) is
   begin
      Self.Configured := True;
      Self.Approach   := Mirror_Host_Addresses;
      Self.Base       := 0;
      Self.Extent     := 0;
      Self.Consumed   := 0;
   end Configure_Mirror;

   --------------
   -- Allocate --
   --------------

   procedure Allocate
     (Self       : in out Allocator;
      Length     : Byte_Count;
      Align_To   : Alignment;
      Host_Value : IOVA_Address;
      IOVA       : out IOVA_Address;
      Succeeded  : out Boolean)
   is
      Step      : constant IOVA_Address := IOVA_Address (Align_To);
      Remaining : constant Byte_Count := Self.Extent - Self.Consumed;
      Start     : IOVA_Address;
      Offset    : IOVA_Address;
      Padding   : Byte_Count;
   begin
      if Self.Approach = Mirror_Host_Addresses then
         IOVA := Host_Value;
         Succeeded := True;
         return;
      end if;

      Start  := Self.Base + IOVA_Address (Self.Consumed);
      Offset := Start mod Step;
      Padding := (if Offset = 0 then 0 else Byte_Count (Step - Offset));

      if Padding > Remaining or else Length > Remaining - Padding then
         IOVA := 0;
         Succeeded := False;
         return;
      end if;

      Self.Consumed := Self.Consumed + Padding;
      IOVA := Self.Base + IOVA_Address (Self.Consumed);
      Self.Consumed := Self.Consumed + Length;
      Succeeded := True;
   end Allocate;

end Flyology_DMA.Address_Space;
