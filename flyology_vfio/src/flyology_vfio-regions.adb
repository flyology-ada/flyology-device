with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Syscalls;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_VFIO.Regions is

   package C renames Interfaces.C;
   package K renames Flyology_VFIO.Thin.Constants;
   package Sys renames Flyology_VFIO.Thin.Syscalls;

   use type C.int;
   use type Flyology_DMA.Byte_Count;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;

   --  The errno a device returns for a region slot it does not fill.
   Invalid_Argument : constant := 22;

   Map_Failed : constant System.Address :=
     System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (K.Mmap_Failed_Sentinel));

   --------------
   -- Describe --
   --------------

   function Describe
     (Device : Device_FD; Index : Region_Index) return Region_Details
   is
      Info : aliased Thin.Region_Info :=
        (Argsz      => Interfaces.Unsigned_32 (K.Region_Info_Size),
         Flags      => 0,
         Index      => Interfaces.Unsigned_32 (Index),
         Cap_Offset => 0,
         Size       => 0,
         Offset     => 0);
   begin
      if Sys.Ioctl (Sys.Raw_FD (Device.Value),
                    C.unsigned_long (K.Device_Get_Region_Info),
                    Info'Address) /= 0
      then
         --  EINVAL here means the device has no such region, which is an
         --  answer rather than a failure: a PCI device reports nine region
         --  slots and fills only the ones it has. Anything else is a real
         --  failure and is raised.
         if Sys.Errno = Invalid_Argument then
            return
              (Index            => Index,
               Implemented      => False,
               Size             => 0,
               Offset           => 0,
               Readable         => False,
               Writable         => False,
               Mappable         => False,
               Has_Capabilities => False);
         end if;

         raise Region_Error with
           "VFIO_DEVICE_GET_REGION_INFO failed for region"
           & Region_Index'Image (Index) & " (" & Sys.Errno_Text & ")";
      end if;

      --  A reply whose argsz came back larger than what was sent means the
      --  kernel has a capability chain for this region — sparse mappable
      --  areas, or the MSI-X table's position within it. The fixed fields it
      --  did fill are valid regardless; reading the chain needs a second
      --  call with a buffer of the size it asked for. Nothing here needs it
      --  yet, so it is reported rather than read, and never treated as an
      --  error.
      return
        (Index            => Index,
         Implemented      => True,
         Size             => Flyology_DMA.Byte_Count (Info.Size),
         Offset           => Info.Offset,
         Readable         =>
           (Info.Flags and Interfaces.Unsigned_32 (K.Region_Flag_Read)) /= 0,
         Writable         =>
           (Info.Flags and Interfaces.Unsigned_32 (K.Region_Flag_Write)) /= 0,
         Mappable         =>
           (Info.Flags and Interfaces.Unsigned_32 (K.Region_Flag_Mmap)) /= 0,
         Has_Capabilities =>
           (Info.Flags and Interfaces.Unsigned_32 (K.Region_Flag_Caps)) /= 0
           or else Info.Argsz > Interfaces.Unsigned_32 (K.Region_Info_Size));
   end Describe;

   ---------
   -- Map --
   ---------

   procedure Map
     (Self   : in out Window;
      Device : Device_FD;
      Index  : Region_Index)
   is
      Details : constant Region_Details := Describe (Device, Index);
      Result  : System.Address;
   begin
      if not Details.Implemented or else Details.Size = 0 then
         raise Region_Error with
           "region" & Region_Index'Image (Index) & " is not implemented by"
           & " this device. A PCI device reports nine region slots and"
           & " fills only the ones it has; iterate with Describe to find"
           & " which.";
      end if;

      if not Details.Mappable then
         raise Region_Error with
           "region" & Region_Index'Image (Index) & " is not mappable."
           & (if Natural (Index) = K.PCI_Config_Region
              then " That region is configuration space, which VFIO never"
                   & " maps: read and write it through"
                   & " Flyology_VFIO.Config_Space instead."
              else " An I/O port base address register cannot be mapped,"
                   & " and neither can one the kernel has withheld. Read"
                   & " and write it with pread and pwrite at its offset.");
      end if;

      Result := Sys.Mmap
        (Addr   => System.Null_Address,
         Length => C.size_t (Details.Size),
         Prot   => C.int (K.Prot_Read) + C.int (K.Prot_Write),
         Flags  => C.int (K.Mmap_Shared),
         FD     => Sys.Raw_FD (Device.Value),
         Offset => C.long (Details.Offset));

      if Result = Map_Failed then
         raise Region_Error with
           "mapping region" & Region_Index'Image (Index) & " of"
           & Flyology_DMA.Byte_Count'Image (Details.Size) & " bytes failed ("
           & Sys.Errno_Text & ")";
      end if;

      Self.Address := Result;
      Self.Extent := Details.Size;
      Self.Region := Index;
      Self.Mapped := True;
   end Map;

   -----------
   -- Unmap --
   -----------

   procedure Unmap (Self : in out Window) is
   begin
      if Self.Mapped then
         --  Clear the state first: if munmap fails there is nothing useful
         --  to do about it, and finalization must not try the same range
         --  again.
         Self.Mapped := False;
         if Sys.Munmap (Self.Address, C.size_t (Self.Extent)) /= 0 then
            null;
         end if;
         Self.Address := System.Null_Address;
         Self.Extent := 0;
      end if;
   end Unmap;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Window) is
   begin
      Unmap (Self);
   end Finalize;

end Flyology_VFIO.Regions;
