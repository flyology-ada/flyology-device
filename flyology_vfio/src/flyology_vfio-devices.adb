with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Syscalls;
with Interfaces.C;

package body Flyology_VFIO.Devices is

   package C renames Interfaces.C;
   package K renames Flyology_VFIO.Thin.Constants;
   package Sys renames Flyology_VFIO.Thin.Syscalls;

   use type C.int;
   use type Interfaces.Unsigned_32;

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Self : Device_FD) return Boolean is
     (Self.Value /= Invalid_Descriptor);

   ------------------
   -- Region_Count --
   ------------------

   function Region_Count (Self : Device_FD) return Natural is
     (Self.Region_Count);

   ---------------
   -- IRQ_Count --
   ---------------

   function IRQ_Count (Self : Device_FD) return Natural is (Self.IRQ_Count);

   ------------
   -- Is_PCI --
   ------------

   function Is_PCI (Self : Device_FD) return Boolean is
     ((Self.Flags and Interfaces.Unsigned_32 (K.Device_Flag_PCI)) /= 0);

   ---------------
   -- Can_Reset --
   ---------------

   function Can_Reset (Self : Device_FD) return Boolean is
     ((Self.Flags and Interfaces.Unsigned_32 (K.Device_Flag_Reset)) /= 0);

   ----------
   -- Open --
   ----------

   procedure Open
     (Self         : in out Device_FD;
      From         : Group_FD;
      In_Container : Container_FD;
      Address      : String)
   is
      pragma Unreferenced (In_Container);

      Name : aliased C.char_array := C.To_C (Address);
      Raw  : C.int;
      Info : aliased Thin.Device_Info :=
        (Argsz       => Interfaces.Unsigned_32 (K.Device_Info_Size),
         Flags       => 0,
         Num_Regions => 0,
         Num_IRQs    => 0,
         Cap_Offset  => 0);
   begin
      --  Unlike every other VFIO request, this one takes a NUL-terminated
      --  string and returns the new descriptor as its result rather than
      --  filling a struct.
      Raw := Sys.Ioctl (Sys.Raw_FD (From.Value),
                        C.unsigned_long (K.Group_Get_Device_FD),
                        Name'Address);

      if Raw < 0 then
         raise Device_Error with
           "VFIO_GROUP_GET_DEVICE_FD failed for " & Address & " ("
           & Sys.Errno_Text & "). The device must belong to group"
           & Natural'Image (Groups.Number (From)) & " and be bound to"
           & " vfio-pci; a device in a different group, or one another"
           & " process already holds, fails here.";
      end if;

      Self.Value := File_Descriptor (Raw);

      if Sys.Ioctl (Raw, C.unsigned_long (K.Device_Get_Info),
                    Info'Address) /= 0
      then
         Sys.Close (Raw);
         Self.Value := Invalid_Descriptor;
         raise Device_Error with
           "VFIO_DEVICE_GET_INFO failed for " & Address & " ("
           & Sys.Errno_Text & ")";
      end if;

      Self.Flags := Info.Flags;
      Self.Region_Count := Natural (Info.Num_Regions);
      Self.IRQ_Count := Natural (Info.Num_IRQs);
   end Open;

   -----------
   -- Reset --
   -----------

   procedure Reset (Self : in out Device_FD) is
   begin
      if Sys.Ioctl (Sys.Raw_FD (Self.Value),
                    C.unsigned_long (K.Device_Reset)) /= 0
      then
         raise Device_Error with
           "VFIO_DEVICE_RESET failed (" & Sys.Errno_Text & ")";
      end if;
   end Reset;

   -----------
   -- Close --
   -----------

   procedure Close (Self : in out Device_FD) is
   begin
      if Self.Value /= Invalid_Descriptor then
         Sys.Close (Sys.Raw_FD (Self.Value));
         Self.Value := Invalid_Descriptor;
      end if;
      Self.Flags := 0;
      Self.Region_Count := 0;
      Self.IRQ_Count := 0;
   end Close;

end Flyology_VFIO.Devices;
