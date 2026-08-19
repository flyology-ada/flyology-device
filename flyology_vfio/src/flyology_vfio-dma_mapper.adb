with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Syscalls;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_VFIO.DMA_Mapper is

   package C renames Interfaces.C;
   package DMA renames Flyology_DMA;
   package K renames Flyology_VFIO.Thin.Constants;
   package Sys renames Flyology_VFIO.Thin.Syscalls;

   use type C.int;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   ----------
   -- Bind --
   ----------

   procedure Bind (Self : in out Container_Mapper; To : Container_FD) is
   begin
      if To.Value = Invalid_Descriptor then
         raise DMA.Mapping_Error with
           "a mapper cannot be bound to a container that is not open";
      end if;

      if not To.IOMMU_Set then
         raise DMA.Mapping_Error with
           "a mapper cannot be bound to a container whose IOMMU has not been"
           & " set. Attach a group first, then call"
           & " Flyology_VFIO.Containers.Set_IOMMU; VFIO_IOMMU_MAP_DMA is"
           & " rejected until both have happened.";
      end if;

      --  A mapper with mappings still live cannot be moved. Its Mappings
      --  will unmap themselves later, and they would do it against
      --  whichever container the mapper points at by then: the ranges the
      --  first container is still holding would leak, and the second would
      --  be asked to remove ranges it never made — or, since every window
      --  in this repository starts at the same address, would remove the
      --  ones it did.
      if Self.Live_Mappings /= 0 then
         raise DMA.Mapping_Error with
           "a mapper with" & Natural'Image (Self.Live_Mappings)
           & " live mapping(s) cannot be bound to another container; release"
           & " them first";
      end if;

      Self.Container := To.Value;
   end Bind;

   ---------
   -- Map --
   ---------

   overriding procedure Map
     (Self      : in out Container_Mapper;
      Host_Base : System.Address;
      Length    : Flyology_DMA.Byte_Count;
      IOVA      : Flyology_DMA.IOVA_Address;
      Direction : Flyology_DMA.Mappers.Device_Access)
   is
      use type DMA.Mappers.Device_Access;

      Flags : constant Interfaces.Unsigned_32 :=
        (case Direction is
            when DMA.Mappers.Device_Reads =>
              Interfaces.Unsigned_32 (K.DMA_Flag_Read),
            when DMA.Mappers.Device_Writes =>
              Interfaces.Unsigned_32 (K.DMA_Flag_Write),
            when DMA.Mappers.Device_Reads_And_Writes =>
              Interfaces.Unsigned_32 (K.DMA_Flag_Read)
              or Interfaces.Unsigned_32 (K.DMA_Flag_Write));

      Request : aliased Thin.DMA_Map :=
        (Argsz => Interfaces.Unsigned_32 (K.DMA_Map_Size),
         Flags => Flags,
         Vaddr =>
           Interfaces.Unsigned_64
             (System.Storage_Elements.To_Integer (Host_Base)),
         IOVA  => Interfaces.Unsigned_64 (IOVA),
         Size  => Interfaces.Unsigned_64 (Length));
   begin
      if not Is_Bound (Self) then
         raise DMA.Mapping_Error with
           "this mapper has not been bound to a container";
      end if;

      if Sys.Ioctl (Sys.Raw_FD (Self.Container),
                    C.unsigned_long (K.Container_Map_DMA),
                    Request'Address) /= 0
      then
         raise DMA.Mapping_Error with
           "VFIO_IOMMU_MAP_DMA of" & DMA.Byte_Count'Image (Length)
           & " bytes at IOVA" & DMA.IOVA_Address'Image (IOVA) & " failed ("
           & Sys.Errno_Text & "). The usual causes, in the order they are"
           & " worth checking: the IOVA range overlaps one already mapped;"
           & " RLIMIT_MEMLOCK is too low for the pages this pins; the"
           & " address or length is not a multiple of a page size the IOMMU"
           & " supports; or the IOVA falls in a range the platform reserves,"
           & " which is what happens when host virtual addresses are"
           & " mirrored into an IOVA space that has reserved windows.";
      end if;
   end Map;

   -----------
   -- Unmap --
   -----------

   overriding procedure Unmap
     (Self   : in out Container_Mapper;
      IOVA   : Flyology_DMA.IOVA_Address;
      Length : Flyology_DMA.Byte_Count)
   is
      Request : aliased Thin.DMA_Unmap :=
        (Argsz => Interfaces.Unsigned_32 (K.DMA_Unmap_Size),
         Flags => 0,
         IOVA  => Interfaces.Unsigned_64 (IOVA),
         Size  => Interfaces.Unsigned_64 (Length));
   begin
      if not Is_Bound (Self) then
         raise DMA.Mapping_Error with
           "this mapper has not been bound to a container";
      end if;

      if Sys.Ioctl (Sys.Raw_FD (Self.Container),
                    C.unsigned_long (K.Container_Unmap_DMA),
                    Request'Address) /= 0
      then
         raise DMA.Mapping_Error with
           "VFIO_IOMMU_UNMAP_DMA of" & DMA.Byte_Count'Image (Length)
           & " bytes at IOVA" & DMA.IOVA_Address'Image (IOVA) & " failed ("
           & Sys.Errno_Text & ")";
      end if;

      --  The kernel reports how much it actually removed in the size field.
      --  A short unmap means the range did not correspond to whole prior
      --  mappings, which is a bookkeeping error worth hearing about rather
      --  than a partial success.
      if Request.Size /= Interfaces.Unsigned_64 (Length) then
         raise DMA.Mapping_Error with
           "VFIO_IOMMU_UNMAP_DMA removed"
           & Interfaces.Unsigned_64'Image (Request.Size) & " of"
           & DMA.Byte_Count'Image (Length) & " bytes at IOVA"
           & DMA.IOVA_Address'Image (IOVA) & ". An unmap removes whole"
           & " prior mappings that fall inside its range and cannot split"
           & " one, so this means the range does not match what was mapped.";
      end if;
   end Unmap;

end Flyology_VFIO.DMA_Mapper;
