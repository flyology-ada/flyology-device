with Flyology_VFIO.Thin.Constants;

--  Compile-time checks that the Ada layouts match the kernel's.
--
--  The representation clauses in the parent package say what this crate
--  believes each struct looks like. This package compares that belief
--  against the sizes and offsets that scripts/generate-constants.sh read
--  from the kernel headers with sizeof and offsetof. A kernel that moves a
--  field, or an architecture that pads differently, breaks the build here
--  instead of having the kernel read one field where another was meant.
--
--  Sizes are compared with 'Object_Size, not 'Size. GNAT's 'Size is the
--  minimum number of bits a value needs and excludes trailing padding, while
--  C's sizeof includes it; for a record ending in a narrow field the two
--  differ, and 'Object_Size is the one that matches C.
--
--  The package has no declarations. Its whole content is the assertions.
--  Deliberately not Pure: the sample objects below are composite constants,
--  which a Pure or Preelaborate unit may not declare, and 'Position needs an
--  object rather than a type name.
package Flyology_VFIO.Thin.Layout is

   package K renames Flyology_VFIO.Thin.Constants;

   --  Always True. It exists so that a unit which wants these assertions in
   --  its own build can reference the package rather than relying on the
   --  project file to compile every source in the directory. The test suite
   --  does exactly that.
   Layouts_Match_The_Kernel : constant Boolean := True;

   --  'Position needs an object, not a type name. These exist only to be
   --  asked where their components sit, and cost nothing at run time.
   Sample_Group_Status : constant Group_Status := (others => 0);
   Sample_Device_Info  : constant Device_Info  := (others => 0);
   Sample_Region_Info  : constant Region_Info  :=
     (Argsz | Flags | Index | Cap_Offset => 0, Size | Offset => 0);
   Sample_IOMMU_Info   : constant IOMMU_Info   :=
     (Argsz | Flags | Cap_Offset => 0, Page_Sizes => 0);
   Sample_DMA_Map      : constant DMA_Map      :=
     (Argsz | Flags => 0, Vaddr | IOVA | Size => 0);
   Sample_DMA_Unmap    : constant DMA_Unmap    :=
     (Argsz | Flags => 0, IOVA | Size => 0);
   Sample_Cap_Header   : constant Info_Cap_Header :=
     (ID | Version => 0, Next => 0);

   pragma Compile_Time_Error
     (Group_Status'Object_Size / 8 /= K.Group_Status_Size,
      "vfio_group_status is not the size the kernel headers report");
   pragma Compile_Time_Error
     (Sample_Group_Status.Argsz'Position /= K.Group_Status_Argsz_Offset,
      "vfio_group_status.argsz is not where the kernel headers put it");
   pragma Compile_Time_Error
     (Sample_Group_Status.Flags'Position /= K.Group_Status_Flags_Offset,
      "vfio_group_status.flags is not where the kernel headers put it");

   pragma Compile_Time_Error
     (Device_Info'Object_Size / 8 /= K.Device_Info_Size,
      "vfio_device_info is not the size the kernel headers report");
   pragma Compile_Time_Error
     (Sample_Device_Info.Num_Regions'Position /= K.Device_Info_Num_Regions_Offset,
      "vfio_device_info.num_regions moved");
   pragma Compile_Time_Error
     (Sample_Device_Info.Num_IRQs'Position /= K.Device_Info_Num_IRQs_Offset,
      "vfio_device_info.num_irqs moved");

   pragma Compile_Time_Error
     (Region_Info'Object_Size / 8 /= K.Region_Info_Size,
      "vfio_region_info is not the size the kernel headers report");
   pragma Compile_Time_Error
     (Sample_Region_Info.Size'Position /= K.Region_Info_Size_Offset,
      "vfio_region_info.size moved");
   pragma Compile_Time_Error
     (Sample_Region_Info.Offset'Position /= K.Region_Info_Offset_Offset,
      "vfio_region_info.offset moved");
   pragma Compile_Time_Error
     (Sample_Region_Info.Cap_Offset'Position /= K.Region_Info_Cap_Offset_Offset,
      "vfio_region_info.cap_offset moved");

   pragma Compile_Time_Error
     (IRQ_Info'Object_Size / 8 /= K.IRQ_Info_Size,
      "vfio_irq_info is not the size the kernel headers report");

   --  The C struct's sizeof is the header alone, because its data member is
   --  a flexible array. That is what makes this comparison meaningful.
   pragma Compile_Time_Error
     (IRQ_Set_Header'Object_Size / 8 /= K.IRQ_Set_Header_Size,
      "the fixed head of vfio_irq_set is not the size the headers report");
   pragma Compile_Time_Error
     (K.IRQ_Set_Data_Offset /= K.IRQ_Set_Header_Size,
      "vfio_irq_set no longer ends in a flexible array member");

   pragma Compile_Time_Error
     (IOMMU_Info'Object_Size / 8 /= K.IOMMU_Info_Size,
      "vfio_iommu_type1_info is not the size the kernel headers report");
   pragma Compile_Time_Error
     (Sample_IOMMU_Info.Page_Sizes'Position /= K.IOMMU_Info_Page_Sizes_Offset,
      "vfio_iommu_type1_info.iova_pgsizes moved");

   pragma Compile_Time_Error
     (DMA_Map'Object_Size / 8 /= K.DMA_Map_Size,
      "vfio_iommu_type1_dma_map is not the size the kernel headers report");
   pragma Compile_Time_Error
     (Sample_DMA_Map.Vaddr'Position /= K.DMA_Map_Vaddr_Offset,
      "vfio_iommu_type1_dma_map.vaddr moved");
   pragma Compile_Time_Error
     (Sample_DMA_Map.IOVA'Position /= K.DMA_Map_IOVA_Offset,
      "vfio_iommu_type1_dma_map.iova moved");
   pragma Compile_Time_Error
     (Sample_DMA_Map.Size'Position /= K.DMA_Map_Size_Offset,
      "vfio_iommu_type1_dma_map.size moved");

   pragma Compile_Time_Error
     (DMA_Unmap'Object_Size / 8 /= K.DMA_Unmap_Size,
      "vfio_iommu_type1_dma_unmap is not the size the headers report");
   pragma Compile_Time_Error
     (Sample_DMA_Unmap.IOVA'Position /= K.DMA_Unmap_IOVA_Offset,
      "vfio_iommu_type1_dma_unmap.iova moved");

   pragma Compile_Time_Error
     (Info_Cap_Header'Object_Size / 8 /= K.Info_Cap_Header_Size,
      "vfio_info_cap_header is not the size the kernel headers report");
   pragma Compile_Time_Error
     (Sample_Cap_Header.Next'Position /= K.Info_Cap_Header_Next_Offset,
      "vfio_info_cap_header.next moved");

end Flyology_VFIO.Thin.Layout;
