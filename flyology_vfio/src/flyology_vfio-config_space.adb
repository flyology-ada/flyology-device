with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Syscalls;
with Interfaces.C;
with System;

package body Flyology_VFIO.Config_Space is

   package C renames Interfaces.C;
   package K renames Flyology_VFIO.Thin.Constants;
   package Sys renames Flyology_VFIO.Thin.Syscalls;

   use type C.int;
   use type C.long;
   use type Interfaces.Unsigned_64;

   --  Where configuration space starts within the device descriptor.
   --
   --  Asked of the kernel each time rather than cached. Configuration space
   --  is not on any hot path — it is touched at start-up and at teardown —
   --  and a cache would have to be invalidated on a reset for no gain.
   function Config_Base (Device : Device_FD) return C.long;

   procedure Read_Raw
     (Device    : Device_FD;
      At_Offset : Config_Offset;
      Buffer    : System.Address;
      Width     : C.size_t);

   procedure Write_Raw
     (Device    : Device_FD;
      At_Offset : Config_Offset;
      Buffer    : System.Address;
      Width     : C.size_t);

   ----------------------
   -- Devices_Is_Open --
   ----------------------

   function Devices_Is_Open (Device : Device_FD) return Boolean is
     (Device.Value /= Invalid_Descriptor);

   -----------------
   -- Config_Base --
   -----------------

   function Config_Base (Device : Device_FD) return C.long is
      Info : aliased Thin.Region_Info :=
        (Argsz      => Interfaces.Unsigned_32 (K.Region_Info_Size),
         Flags      => 0,
         Index      => Interfaces.Unsigned_32 (K.PCI_Config_Region),
         Cap_Offset => 0,
         Size       => 0,
         Offset     => 0);
   begin
      if Sys.Ioctl (Sys.Raw_FD (Device.Value),
                    C.unsigned_long (K.Device_Get_Region_Info),
                    Info'Address) /= 0
      then
         raise Device_Error with
           "could not locate configuration space (" & Sys.Errno_Text
           & "). Only a PCI device has a configuration region.";
      end if;
      return C.long (Info.Offset);
   end Config_Base;

   --------------
   -- Read_Raw --
   --------------

   procedure Read_Raw
     (Device    : Device_FD;
      At_Offset : Config_Offset;
      Buffer    : System.Address;
      Width     : C.size_t)
   is
      Got : constant C.long :=
        Sys.Pread (Sys.Raw_FD (Device.Value), Buffer, Width,
                   Config_Base (Device) + C.long (At_Offset));
   begin
      if Got /= C.long (Width) then
         raise Device_Error with
           "reading" & C.size_t'Image (Width) & " byte(s) of configuration"
           & " space at offset" & Config_Offset'Image (At_Offset)
           & " returned" & C.long'Image (Got) & " (" & Sys.Errno_Text & ")";
      end if;
   end Read_Raw;

   ---------------
   -- Write_Raw --
   ---------------

   procedure Write_Raw
     (Device    : Device_FD;
      At_Offset : Config_Offset;
      Buffer    : System.Address;
      Width     : C.size_t)
   is
      Put : constant C.long :=
        Sys.Pwrite (Sys.Raw_FD (Device.Value), Buffer, Width,
                    Config_Base (Device) + C.long (At_Offset));
   begin
      if Put /= C.long (Width) then
         raise Device_Error with
           "writing" & C.size_t'Image (Width) & " byte(s) of configuration"
           & " space at offset" & Config_Offset'Image (At_Offset)
           & " returned" & C.long'Image (Put) & " (" & Sys.Errno_Text
           & "). The kernel mediates configuration space and refuses writes"
           & " to the fields it manages.";
      end if;
   end Write_Raw;

   ------------
   -- Read_8 --
   ------------

   function Read_8 (Device : Device_FD; At_Offset : Config_Offset) return U8
   is
      Value : aliased U8 := 0;
   begin
      Read_Raw (Device, At_Offset, Value'Address, 1);
      return Value;
   end Read_8;

   -------------
   -- Read_16 --
   -------------

   function Read_16
     (Device : Device_FD; At_Offset : Config_Offset) return U16
   is
      Value : aliased U16 := 0;
   begin
      Read_Raw (Device, At_Offset, Value'Address, 2);
      return Value;
   end Read_16;

   -------------
   -- Read_32 --
   -------------

   function Read_32
     (Device : Device_FD; At_Offset : Config_Offset) return U32
   is
      Value : aliased U32 := 0;
   begin
      Read_Raw (Device, At_Offset, Value'Address, 4);
      return Value;
   end Read_32;

   --------------
   -- Write_16 --
   --------------

   procedure Write_16
     (Device : Device_FD; At_Offset : Config_Offset; Value : U16)
   is
      Local : aliased U16 := Value;
   begin
      Write_Raw (Device, At_Offset, Local'Address, 2);
   end Write_16;

   --------------
   -- Write_32 --
   --------------

   procedure Write_32
     (Device : Device_FD; At_Offset : Config_Offset; Value : U32)
   is
      Local : aliased U32 := Value;
   begin
      Write_Raw (Device, At_Offset, Local'Address, 4);
   end Write_32;

   ---------------
   -- Vendor_ID --
   ---------------

   function Vendor_ID (Device : Device_FD) return U16 is
     (Read_16 (Device, Vendor_ID_Offset));

   ---------------
   -- Device_ID --
   ---------------

   function Device_ID (Device : Device_FD) return U16 is
     (Read_16 (Device, Device_ID_Offset));

   -----------------------------
   -- Bus_Mastering_Enabled --
   -----------------------------

   function Bus_Mastering_Enabled (Device : Device_FD) return Boolean is
     ((Read_16 (Device, Command_Offset) and Command_Bus_Master) /= 0);

   ----------------------------
   -- Enable_Bus_Mastering --
   ----------------------------

   procedure Enable_Bus_Mastering (Device : Device_FD) is
      Command : constant U16 := Read_16 (Device, Command_Offset);
   begin
      --  Read, set one bit, write the whole register back. The command
      --  register is an ordinary read-write register with no bits that
      --  clear on read or on writing a one, so this sequence is safe here
      --  in a way it would not be for a status register.
      if (Command and Command_Bus_Master) = 0 then
         Write_16 (Device, Command_Offset, Command or Command_Bus_Master);
      end if;
   end Enable_Bus_Mastering;

   -----------------------------
   -- Disable_Bus_Mastering --
   -----------------------------

   procedure Disable_Bus_Mastering (Device : Device_FD) is
      Command : constant U16 := Read_16 (Device, Command_Offset);
   begin
      if (Command and Command_Bus_Master) /= 0 then
         Write_16 (Device, Command_Offset, Command and not Command_Bus_Master);
      end if;
   end Disable_Bus_Mastering;

   ----------------------------
   -- Memory_Space_Enabled --
   ----------------------------

   function Memory_Space_Enabled (Device : Device_FD) return Boolean is
     ((Read_16 (Device, Command_Offset) and Command_Memory_Space) /= 0);

   ---------------------------
   -- Enable_Memory_Space --
   ---------------------------

   procedure Enable_Memory_Space (Device : Device_FD) is
      Command : constant U16 := Read_16 (Device, Command_Offset);
   begin
      if (Command and Command_Memory_Space) = 0 then
         Write_16 (Device, Command_Offset, Command or Command_Memory_Space);
      end if;
   end Enable_Memory_Space;

end Flyology_VFIO.Config_Space;
