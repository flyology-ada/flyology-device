with Flyology_VFIO.Thin.Syscalls;

package body Flyology_VFIO is

   package Sys renames Flyology_VFIO.Thin.Syscalls;

   --  Closing is the same three lines for all three descriptors, and the
   --  order matters more than the code: a device is finalized before the
   --  group it came from, and a group before its container, which happens
   --  for free when they are declared in that order.
   procedure Release (Value : in out File_Descriptor);

   -------------
   -- Release --
   -------------

   procedure Release (Value : in out File_Descriptor) is
   begin
      if Value /= Invalid_Descriptor then
         Sys.Close (Sys.Raw_FD (Value));
         Value := Invalid_Descriptor;
      end if;
   end Release;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Container_FD) is
   begin
      --  Closing a container releases every DMA mapping made through it.
      --  That is the kernel's backstop, not this crate's design: mappings
      --  are removed by the Mapping values that own them, and this only
      --  catches what a process leaked on its way out.
      Release (Self.Value);
      Self.Groups := 0;
      Self.IOMMU_Set := False;
   end Finalize;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Group_FD) is
   begin
      Release (Self.Value);
      Self.Attached := False;
   end Finalize;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Device_FD) is
   begin
      --  vfio-pci disables the device when its descriptor closes, which
      --  includes clearing bus mastering. Nothing here needs to do that.
      Release (Self.Value);
      Self.Region_Count := 0;
      Self.IRQ_Count := 0;
   end Finalize;

end Flyology_VFIO;
