with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Syscalls;
with Interfaces.C;

package body Flyology_VFIO.Groups is

   package C renames Interfaces.C;
   package K renames Flyology_VFIO.Thin.Constants;
   package Sys renames Flyology_VFIO.Thin.Syscalls;

   use type C.int;
   use type Interfaces.Unsigned_32;

   function Node_Path (Number : Natural) return String is
     ("/dev/vfio/" & Ada.Strings.Fixed.Trim
        (Natural'Image (Number), Ada.Strings.Both));

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Self : Group_FD) return Boolean is
     (Self.Value /= Invalid_Descriptor);

   ------------
   -- Number --
   ------------

   function Number (Self : Group_FD) return Natural is (Self.Number);

   -----------------
   -- Is_Attached --
   -----------------

   function Is_Attached (Self : Group_FD) return Boolean is (Self.Attached);

   --------------------
   -- Is_Attached_To --
   --------------------

   function Is_Attached_To
     (Self : Group_FD; Candidate : Container_FD) return Boolean
   is (Self.Attached and then Self.Container = Candidate.Value);

   ----------
   -- Open --
   ----------

   procedure Open (Self : in out Group_FD; Number : Natural) is
      Path   : constant String := Node_Path (Number);
      Raw    : Sys.Raw_FD;
      Status : aliased Thin.Group_Status :=
        (Argsz => Interfaces.Unsigned_32 (K.Group_Status_Size), Flags => 0);
   begin
      Raw := Sys.Open_Read_Write (Path);

      if Raw = Sys.Invalid then
         raise VFIO_Unavailable with
           "could not open " & Path & " (" & Sys.Errno_Text & ")."
           & (if Ada.Directories.Exists ("/dev/vfio/noiommu-"
                & Ada.Strings.Fixed.Trim (Natural'Image (Number),
                                          Ada.Strings.Both))
              then " A no-IOMMU node exists for this group instead, which"
                   & " means the host has no IOMMU. This crate does not use"
                   & " no-IOMMU mode: there a device consumes physical"
                   & " addresses and no mapping ioctl exists."
              else " The group node appears when a device in the group is"
                   & " bound to vfio-pci. Bind one with: echo vfio-pci >"
                   & " /sys/bus/pci/devices/<address>/driver_override and"
                   & " then write the address to"
                   & " /sys/bus/pci/drivers/vfio-pci/bind.");
      end if;

      Self.Value := File_Descriptor (Raw);
      Self.Number := Number;
      Self.Attached := False;
      Self.Container := Invalid_Descriptor;

      if Sys.Ioctl (Raw, C.unsigned_long (K.Group_Get_Status),
                    Status'Address) /= 0
      then
         Sys.Close (Raw);
         Self.Value := Invalid_Descriptor;
         raise Group_Error with
           "VFIO_GROUP_GET_STATUS failed on " & Path & " ("
           & Sys.Errno_Text & ")";
      end if;

      if (Status.Flags and Interfaces.Unsigned_32 (K.Group_Flag_Viable)) = 0
      then
         Sys.Close (Raw);
         Self.Value := Invalid_Descriptor;
         raise Group_Not_Viable with
           "IOMMU group" & Natural'Image (Number) & " is not viable, which"
           & " means at least one device in it is still bound to a kernel"
           & " driver. VFIO assigns whole groups because the hardware"
           & " cannot isolate more finely. List the group's devices with:"
           & " ls /sys/kernel/iommu_groups/"
           & Ada.Strings.Fixed.Trim (Natural'Image (Number),
                                     Ada.Strings.Both)
           & "/devices, and unbind or rebind each one that still has a"
           & " driver. Never unbind a device the running system depends on.";
      end if;
   end Open;

   ------------
   -- Attach --
   ------------

   procedure Attach (Self : in out Group_FD; To : in out Container_FD) is
      --  This request takes the container descriptor by pointer, not by
      --  value, which is not something the request number reveals. The
      --  kernel reads it with get_user, so passing the descriptor directly
      --  is rejected with EFAULT — a failure that says "bad address" about
      --  a call containing no address at all.
      --
      --  The asymmetry is real and worth stating: VFIO_CHECK_EXTENSION and
      --  VFIO_SET_IOMMU on a container both take their argument by value,
      --  and only this one takes a pointer.
      Descriptor : aliased C.int := C.int (To.Value);
   begin
      if Sys.Ioctl (Sys.Raw_FD (Self.Value),
                    C.unsigned_long (K.Group_Set_Container),
                    Descriptor'Address) /= 0
      then
         raise Group_Error with
           "VFIO_GROUP_SET_CONTAINER failed for group"
           & Natural'Image (Self.Number) & " (" & Sys.Errno_Text & "). A"
           & " group can only join a container that has no incompatible"
           & " IOMMU already set, and only one container at a time.";
      end if;

      Self.Attached := True;
      Self.Container := To.Value;
      To.Groups := To.Groups + 1;
   end Attach;

   ------------
   -- Detach --
   ------------

   procedure Detach (Self : in out Group_FD; From : in out Container_FD) is
   begin
      --  The kernel's own teardown makes a failure here uninteresting: the
      --  group leaves the container when either descriptor closes. Reporting
      --  it would only obscure whatever went wrong first.
      if Sys.Ioctl (Sys.Raw_FD (Self.Value),
                    C.unsigned_long (K.Group_Unset_Container)) = 0
        and then From.Groups > 0
      then
         From.Groups := From.Groups - 1;
      end if;

      Self.Attached := False;
      Self.Container := Invalid_Descriptor;
   end Detach;

   -----------
   -- Close --
   -----------

   procedure Close (Self : in out Group_FD) is
   begin
      if Self.Value /= Invalid_Descriptor then
         Sys.Close (Sys.Raw_FD (Self.Value));
         Self.Value := Invalid_Descriptor;
      end if;
      Self.Attached := False;
      Self.Container := Invalid_Descriptor;
   end Close;

   --------------
   -- Group_Of --
   --------------

   function Group_Of (Address : String) return Natural is
      Link : constant String :=
        "/sys/bus/pci/devices/" & Address & "/iommu_group";
   begin
      if not Ada.Directories.Exists ("/sys/bus/pci/devices/" & Address) then
         raise VFIO_Unavailable with
           "there is no PCI device at " & Address & ". Addresses are in the"
           & " full domain:bus:device.function form, such as 0000:00:02.0.";
      end if;

      if not Ada.Directories.Exists (Link) then
         raise VFIO_Unavailable with
           Address & " is in no IOMMU group. Either the host has no IOMMU"
           & " enabled — check that /sys/kernel/iommu_groups is not empty,"
           & " and boot with intel_iommu=on or amd_iommu=on on x86 — or the"
           & " device has not yet been claimed by a driver that joins one."
           & " Binding it to vfio-pci is what puts most devices in a group.";
      end if;

      --  The link's target ends in the group number: it points at
      --  ../../../kernel/iommu_groups/<n>. Reading the target's simple name
      --  is how the number is recovered, because sysfs offers it nowhere
      --  else in scalar form.
      declare
         Target : constant String := Ada.Directories.Full_Name (Link);
         Last   : Natural := Target'Last;
         First  : Natural;
      begin
         while Last > Target'First and then Target (Last) = '/' loop
            Last := Last - 1;
         end loop;
         First := Last;
         while First > Target'First
           and then Target (First - 1) in '0' .. '9'
         loop
            First := First - 1;
         end loop;
         return Natural'Value (Target (First .. Last));
      end;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Constraint_Error =>
         raise VFIO_Unavailable with
           "could not read the IOMMU group number of " & Address
           & " from " & Link;
   end Group_Of;

end Flyology_VFIO.Groups;
