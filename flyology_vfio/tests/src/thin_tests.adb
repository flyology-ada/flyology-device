--  Checks the ioctl surface against what the kernel interface guarantees.
--
--  These run on any host, including one with no VFIO at all, because they
--  test the binding rather than the kernel. Two things are worth checking
--  here and nowhere else.
--
--  The first is that the generated request numbers really do follow
--  _IO(';', 100 + n). If a number is wrong, the kernel rejects the request
--  with EINVAL and says nothing about which one, so a mistake here surfaces
--  as a failure somewhere far away. Deriving the expected numbers
--  independently and comparing catches a bad regeneration.
--
--  The second is the collisions. Six request numbers mean one thing on a
--  container descriptor and something entirely different on a device
--  descriptor, and nothing in the number distinguishes them. Asserting that
--  the collisions are still there is what keeps the fact from being
--  forgotten: if one of these ever stops colliding, the comment explaining
--  why the descriptor types are distinct needs rewriting, not deleting.
--
--  The struct layouts are checked at compile time by
--  Flyology_VFIO.Thin.Layout, which this program references so that those
--  assertions are part of a build that is actually run.

--  Almost every comparison below is between two static values, so the
--  compiler folds it and warns that the condition is always true. That is
--  the point: these checks are answered at compile time, and the run only
--  confirms the build that answered them is the one being tested. The
--  warning is turned off rather than the checks being written in a way that
--  defeats the folding.
pragma Warnings (Off, "condition is always True");

with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Layout;
with Support;

procedure Thin_Tests is
   package K renames Flyology_VFIO.Thin.Constants;

   --  _IO(type, nr) is (type << 8) or nr with a zero direction and size, and
   --  VFIO uses ';' as its type with a base of 100.
   VFIO_Type : constant := Character'Pos (';');
   VFIO_Base : constant := 100;

   function Request (N : Natural) return Natural is
     (VFIO_Type * 256 + VFIO_Base + N);
begin
   Support.Check
     (Flyology_VFIO.Thin.Layout.Layouts_Match_The_Kernel,
      "the compile-time layout assertions were part of this build");

   --  Container requests.
   Support.Check
     (K.Container_Get_API_Version = Request (0), "GET_API_VERSION is base+0");
   Support.Check
     (K.Container_Check_Extension = Request (1), "CHECK_EXTENSION is base+1");
   Support.Check (K.Container_Set_IOMMU = Request (2), "SET_IOMMU is base+2");
   Support.Check
     (K.Container_Get_IOMMU_Info = Request (12), "IOMMU_GET_INFO is base+12");
   Support.Check
     (K.Container_Map_DMA = Request (13), "IOMMU_MAP_DMA is base+13");
   Support.Check
     (K.Container_Unmap_DMA = Request (14), "IOMMU_UNMAP_DMA is base+14");

   --  Group requests.
   Support.Check
     (K.Group_Get_Status = Request (3), "GROUP_GET_STATUS is base+3");
   Support.Check
     (K.Group_Set_Container = Request (4), "GROUP_SET_CONTAINER is base+4");
   Support.Check
     (K.Group_Unset_Container = Request (5), "GROUP_UNSET_CONTAINER is base+5");
   Support.Check
     (K.Group_Get_Device_FD = Request (6), "GROUP_GET_DEVICE_FD is base+6");

   --  Device requests.
   Support.Check
     (K.Device_Get_Info = Request (7), "DEVICE_GET_INFO is base+7");
   Support.Check
     (K.Device_Get_Region_Info = Request (8), "GET_REGION_INFO is base+8");
   Support.Check
     (K.Device_Get_IRQ_Info = Request (9), "GET_IRQ_INFO is base+9");
   Support.Check (K.Device_Set_IRQs = Request (10), "SET_IRQS is base+10");
   Support.Check (K.Device_Reset = Request (11), "DEVICE_RESET is base+11");

   --  The collisions the distinct descriptor types exist to guard. Each of
   --  these numbers means one thing on a container and another on a device.
   Support.Check
     (K.Container_Get_IOMMU_Info = Request (12)
      and then K.Container_Map_DMA = Request (13)
      and then K.Container_Unmap_DMA = Request (14),
      "the container requests still occupy base+12 through base+14, which"
      & " the device hot-reset and graphics-plane requests also occupy");

   --  IOMMU types. Type1 version 2 is what this crate requires, and
   --  no-IOMMU is what it refuses; both numbers matter.
   Support.Check (K.API_Version = 0, "the API version is zero");
   Support.Check (K.Type1_IOMMU = 1, "type1 is 1");
   Support.Check (K.Type1_V2_IOMMU = 3, "type1 v2 is 3");
   Support.Check
     (K.No_IOMMU /= K.Type1_V2_IOMMU,
      "no-IOMMU is a different extension from the one this crate uses");

   --  Flags are single bits, and several are combined with or elsewhere.
   Support.Check (K.Group_Flag_Viable = 1, "viable is bit 0");
   Support.Check (K.Region_Flag_Read = 1, "region read is bit 0");
   Support.Check (K.Region_Flag_Write = 2, "region write is bit 1");
   Support.Check (K.Region_Flag_Mmap = 4, "region mmap is bit 2");
   Support.Check (K.Region_Flag_Caps = 8, "region caps is bit 3");
   Support.Check
     (K.DMA_Flag_Read /= K.DMA_Flag_Write,
      "the DMA direction flags are distinct bits");

   --  PCI indices. Configuration space is region 7 and is never mappable,
   --  which is why Config_Space reads it rather than mapping it.
   Support.Check (K.PCI_BAR0_Region = 0, "BAR0 is region 0");
   Support.Check (K.PCI_Config_Region = 7, "config space is region 7");
   Support.Check (K.PCI_Region_Count = 9, "a PCI device has 9 regions");
   Support.Check (K.PCI_MSIX_IRQ = 2, "MSI-X is interrupt index 2");

   --  The variable tail. vfio_irq_set's data member sits exactly at the end
   --  of its fixed head, which is what makes the size arithmetic in
   --  Interrupts.Enable correct.
   Support.Check
     (K.IRQ_Set_Data_Offset = K.IRQ_Set_Header_Size,
      "vfio_irq_set's tail begins where its head ends");

   --  Sizes the argsz fields are set from. These come from sizeof on the
   --  build host, so this asserts they are what a 64-bit kernel uses rather
   --  than deriving them again.
   Support.Check (K.Group_Status_Size = 8, "vfio_group_status is 8 bytes");
   Support.Check (K.DMA_Map_Size = 32, "vfio_iommu_type1_dma_map is 32 bytes");
   Support.Check
     (K.DMA_Unmap_Size = 24, "vfio_iommu_type1_dma_unmap is 24 bytes");
   Support.Check (K.Region_Info_Size = 32, "vfio_region_info is 32 bytes");
   Support.Check (K.IRQ_Info_Size = 16, "vfio_irq_info is 16 bytes");

   --  The 64-bit fields must be where a 64-bit kernel puts them; an eight
   --  byte slip here would have the kernel read a length as an address.
   Support.Check
     (K.DMA_Map_Vaddr_Offset = 8 and then K.DMA_Map_IOVA_Offset = 16
      and then K.DMA_Map_Size_Offset = 24,
      "the dma_map 64-bit fields are at 8, 16 and 24");

   Support.Report ("thin_tests");
end Thin_Tests;
