with Interfaces;

--  The VFIO ioctl surface: request numbers, argument layouts, and nothing
--  else.
--
--  This package holds no policy. It does not know that a group must be
--  attached before the IOMMU is set, or that bus mastering has to be
--  enabled; those belong to the packages above it. What it guarantees is
--  that the numbers and layouts are the kernel's, checked rather than
--  believed.
--
--  Two properties of the VFIO interface make this binding unusually
--  tractable from a language that cannot read C headers.
--
--  The first is that every VFIO request number is a bare _IO(';', 100 + n)
--  with no size encoded in it. _IOR and _IOW embed sizeof of the argument
--  type, which a non-C compiler cannot compute without replicating C's
--  layout rules; VFIO instead carries an argsz field as the first member of
--  every argument struct and validates against that. So the request numbers
--  are plain integers.
--
--  The second is that argsz makes the kernel tolerant of a struct that is
--  smaller than the one it knows: it fills what fits and reports the size it
--  would have liked. That is what makes the capability chains queryable at
--  all, and it means a stale binding degrades rather than corrupting.
--
--  What is not tractable, and is handled explicitly below, is that argsz is
--  not simply the size of a record. Structs ending in a variable-length tail
--  need the header size plus the payload, and structs carrying capability
--  chains need two calls: one to learn the size, one to read it.
package Flyology_VFIO.Thin
  with Preelaborate
is

   --  The kernel's fixed-width integers, named as the headers name them so
   --  that a layout can be read against the C struct beside it.
   subtype U8 is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;
   subtype S32 is Interfaces.Integer_32;

   --  struct vfio_group_status
   type Group_Status is record
      Argsz : U32;
      Flags : U32;
   end record
     with Convention => C;
   for Group_Status use record
      Argsz at 0 range 0 .. 31;
      Flags at 4 range 0 .. 31;
   end record;

   --  struct vfio_device_info
   type Device_Info is record
      Argsz       : U32;
      Flags       : U32;
      Num_Regions : U32;
      Num_IRQs    : U32;
      Cap_Offset  : U32;
   end record
     with Convention => C;
   for Device_Info use record
      Argsz       at 0  range 0 .. 31;
      Flags       at 4  range 0 .. 31;
      Num_Regions at 8  range 0 .. 31;
      Num_IRQs    at 12 range 0 .. 31;
      Cap_Offset  at 16 range 0 .. 31;
   end record;

   --  struct vfio_region_info
   --
   --  Offset is where in the device file descriptor the region lives, which
   --  is what a read, a write, or an mmap of that region uses. It is not a
   --  physical address and is unrelated to the BAR's address on the bus.
   type Region_Info is record
      Argsz      : U32;
      Flags      : U32;
      Index      : U32;
      Cap_Offset : U32;
      Size       : U64;
      Offset     : U64;
   end record
     with Convention => C;
   for Region_Info use record
      Argsz      at 0  range 0 .. 31;
      Flags      at 4  range 0 .. 31;
      Index      at 8  range 0 .. 31;
      Cap_Offset at 12 range 0 .. 31;
      Size       at 16 range 0 .. 63;
      Offset     at 24 range 0 .. 63;
   end record;

   --  struct vfio_irq_info
   type IRQ_Info is record
      Argsz : U32;
      Flags : U32;
      Index : U32;
      Count : U32;
   end record
     with Convention => C;
   for IRQ_Info use record
      Argsz at 0  range 0 .. 31;
      Flags at 4  range 0 .. 31;
      Index at 8  range 0 .. 31;
      Count at 12 range 0 .. 31;
   end record;

   --  The fixed head of struct vfio_irq_set.
   --
   --  The C struct ends in a flexible array member, so its sizeof is this
   --  header alone and argsz must be this plus the payload the flags imply.
   --  A caller that set argsz from the header size alone while also setting
   --  DATA_EVENTFD would be rejected with EINVAL, which is the kernel
   --  catching exactly this mistake.
   type IRQ_Set_Header is record
      Argsz : U32;
      Flags : U32;
      Index : U32;
      Start : U32;
      Count : U32;
   end record
     with Convention => C;
   for IRQ_Set_Header use record
      Argsz at 0  range 0 .. 31;
      Flags at 4  range 0 .. 31;
      Index at 8  range 0 .. 31;
      Start at 12 range 0 .. 31;
      Count at 16 range 0 .. 31;
   end record;

   --  struct vfio_iommu_type1_info
   type IOMMU_Info is record
      Argsz      : U32;
      Flags      : U32;
      Page_Sizes : U64;
      Cap_Offset : U32;
   end record
     with Convention => C;
   for IOMMU_Info use record
      Argsz      at 0  range 0 .. 31;
      Flags      at 4  range 0 .. 31;
      Page_Sizes at 8  range 0 .. 63;
      Cap_Offset at 16 range 0 .. 31;
   end record;

   --  struct vfio_iommu_type1_dma_map
   --
   --  Vaddr is a host virtual address and IOVA is what the device will emit.
   --  They are separate fields for a reason, and the whole point of the
   --  mapping is that they need not be equal.
   type DMA_Map is record
      Argsz : U32;
      Flags : U32;
      Vaddr : U64;
      IOVA  : U64;
      Size  : U64;
   end record
     with Convention => C;
   for DMA_Map use record
      Argsz at 0  range 0 .. 31;
      Flags at 4  range 0 .. 31;
      Vaddr at 8  range 0 .. 63;
      IOVA  at 16 range 0 .. 63;
      Size  at 24 range 0 .. 63;
   end record;

   --  struct vfio_iommu_type1_dma_unmap
   --
   --  An unmap removes whole prior mappings that fall inside its range. The
   --  type1 IOMMU cannot split one, so this crate only ever unmaps exactly
   --  what it mapped.
   type DMA_Unmap is record
      Argsz : U32;
      Flags : U32;
      IOVA  : U64;
      Size  : U64;
   end record
     with Convention => C;
   for DMA_Unmap use record
      Argsz at 0  range 0 .. 31;
      Flags at 4  range 0 .. 31;
      IOVA  at 8  range 0 .. 63;
      Size  at 16 range 0 .. 63;
   end record;

   --  struct vfio_info_cap_header, the link in a capability chain.
   --
   --  Next is a byte offset from the start of the reply buffer, not from
   --  this header, and a zero ends the chain.
   type Info_Cap_Header is record
      ID      : U16;
      Version : U16;
      Next    : U32;
   end record
     with Convention => C;
   for Info_Cap_Header use record
      ID      at 0 range 0 .. 15;
      Version at 2 range 0 .. 15;
      Next    at 4 range 0 .. 31;
   end record;

end Flyology_VFIO.Thin;
