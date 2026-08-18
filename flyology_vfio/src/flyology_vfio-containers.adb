with Ada.Directories;
with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Syscalls;
with Interfaces.C;

package body Flyology_VFIO.Containers is

   package C renames Interfaces.C;
   package K renames Flyology_VFIO.Thin.Constants;
   package Sys renames Flyology_VFIO.Thin.Syscalls;

   use type C.int;
   use type Interfaces.Unsigned_32;

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Self : Container_FD) return Boolean is
     (Self.Value /= Invalid_Descriptor);

   ---------------------
   -- Attached_Groups --
   ---------------------

   function Attached_Groups (Self : Container_FD) return Natural is
     (Self.Groups);

   -------------------
   -- IOMMU_Is_Set --
   -------------------

   function IOMMU_Is_Set (Self : Container_FD) return Boolean is
     (Self.IOMMU_Set);

   ----------
   -- Open --
   ----------

   procedure Open (Self : in out Container_FD) is
      Raw     : Sys.Raw_FD;
      Version : C.int;
   begin
      Raw := Sys.Open_Read_Write (Device_Node);

      if Raw = Sys.Invalid then
         --  Distinguish the three shapes of absence, because they need three
         --  different things done about them.
         if not Ada.Directories.Exists ("/dev/vfio") then
            raise VFIO_Unavailable with
              "/dev/vfio does not exist, so no VFIO interface is present."
              & " Load the vfio-pci module (modprobe vfio-pci), and check"
              & " that the kernel was booted with an IOMMU enabled:"
              & " intel_iommu=on or amd_iommu=on on x86, and an SMMU on"
              & " arm64. " & Sys.Errno_Text;
         elsif not Ada.Directories.Exists (Device_Node) then
            raise VFIO_Unavailable with
              "/dev/vfio exists but " & Device_Node & " does not."
              & (if Ada.Directories.Exists ("/dev/vfio/devices")
                 then " This kernel offers only the newer IOMMUFD character"
                      & " devices under /dev/vfio/devices. This crate binds"
                      & " the legacy container interface, which that kernel"
                      & " was built without."
                 else " The vfio module may be partly loaded.")
              & " " & Sys.Errno_Text;
         else
            raise VFIO_Unavailable with
              "could not open " & Device_Node & " (" & Sys.Errno_Text
              & "). Check that the process may open it: VFIO normally"
              & " requires membership of the group that owns the node, or"
              & " CAP_SYS_ADMIN.";
         end if;
      end if;

      Self.Value := File_Descriptor (Raw);
      Self.Groups := 0;
      Self.IOMMU_Set := False;

      Version := Sys.Ioctl (Raw, C.unsigned_long (K.Container_Get_API_Version));
      if Version /= C.int (K.API_Version) then
         Sys.Close (Raw);
         Self.Value := Invalid_Descriptor;
         raise API_Mismatch with
           "the kernel reports VFIO API version" & C.int'Image (Version)
           & ", and this crate implements version"
           & Integer'Image (K.API_Version)
           & ". VFIO has had one version for its whole life, so this is"
           & " more surprising than a version bump and worth investigating"
           & " before going further.";
      end if;

      if Sys.Ioctl (Raw, C.unsigned_long (K.Container_Check_Extension),
                    C.int (K.Type1_V2_IOMMU)) = 0
      then
         declare
            Has_No_IOMMU : constant Boolean :=
              Sys.Ioctl (Raw, C.unsigned_long (K.Container_Check_Extension),
                         C.int (K.No_IOMMU)) /= 0;
         begin
            Sys.Close (Raw);
            Self.Value := Invalid_Descriptor;
            raise IOMMU_Unsupported with
              "this kernel does not offer the type1 version 2 IOMMU."
              & (if Has_No_IOMMU
                 then " It does offer no-IOMMU mode, which this crate"
                      & " deliberately does not use: in that mode a device"
                      & " consumes physical addresses, no mapping ioctl"
                      & " exists, and nothing this crate does would mean"
                      & " what it says."
                 else " Check that an IOMMU is enabled on the kernel command"
                      & " line: intel_iommu=on or amd_iommu=on on x86."
                      & " /sys/kernel/iommu_groups is empty when it is not.");
         end;
      end if;
   end Open;

   ---------------
   -- Set_IOMMU --
   ---------------

   procedure Set_IOMMU (Self : in out Container_FD) is
      Raw : constant Sys.Raw_FD := Sys.Raw_FD (Self.Value);
   begin
      if Sys.Ioctl (Raw, C.unsigned_long (K.Container_Set_IOMMU),
                    C.int (K.Type1_V2_IOMMU)) /= 0
      then
         raise IOMMU_Unsupported with
           "VFIO_SET_IOMMU was refused (" & Sys.Errno_Text & ") with"
           & Natural'Image (Self.Groups) & " group(s) attached. The usual"
           & " cause is that no group is attached yet, which this call"
           & " already requires; the next most likely is that another"
           & " process holds one of this group's devices.";
      end if;
      Self.IOMMU_Set := True;
   end Set_IOMMU;

   --------------------------
   -- Supported_Page_Sizes --
   --------------------------

   function Supported_Page_Sizes
     (Self : Container_FD) return Interfaces.Unsigned_64
   is
      Info : aliased Thin.IOMMU_Info :=
        (Argsz      => Interfaces.Unsigned_32 (K.IOMMU_Info_Size),
         Flags      => 0,
         Page_Sizes => 0,
         Cap_Offset => 0);
   begin
      if Sys.Ioctl (Sys.Raw_FD (Self.Value),
                    C.unsigned_long (K.Container_Get_IOMMU_Info),
                    Info'Address) /= 0
      then
         return 0;
      end if;

      --  The kernel may report a larger argsz than was sent, meaning it has
      --  a capability chain to offer. That is not an error, and the fixed
      --  fields it did fill are valid; reading the chain would need a second
      --  call with a buffer of the size it asked for, which nothing here
      --  needs yet.
      if (Info.Flags and Interfaces.Unsigned_32 (K.IOMMU_Info_Page_Sizes)) = 0
      then
         return 0;
      end if;

      return Info.Page_Sizes;
   end Supported_Page_Sizes;

   -----------
   -- Close --
   -----------

   procedure Close (Self : in out Container_FD) is
   begin
      if Self.Value /= Invalid_Descriptor then
         Sys.Close (Sys.Raw_FD (Self.Value));
         Self.Value := Invalid_Descriptor;
      end if;
      Self.Groups := 0;
      Self.IOMMU_Set := False;
   end Close;

end Flyology_VFIO.Containers;
