with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;

package body Flyology_VFIO_QEMU is

   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   Devices_Root : constant String := "/sys/bus/pci/devices";

   --  Reads a sysfs file holding a value like "0x1234", returning zero when
   --  the file is absent or unreadable. Every caller is deciding whether a
   --  device is the one it wants, and an unreadable identity is not it.
   function Read_Hex_File (Path : String) return U32;

   -------------------
   -- Read_Hex_File --
   -------------------

   function Read_Hex_File (Path : String) return U32 is
      File : Ada.Text_IO.File_Type;
      Line : String (1 .. 32);
      Last : Natural;
   begin
      if not Ada.Directories.Exists (Path) then
         return 0;
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      Ada.Text_IO.Get_Line (File, Line, Last);
      Ada.Text_IO.Close (File);

      --  sysfs writes these as 0x1234, which Ada reads as 16#1234#.
      declare
         Text : constant String :=
           Ada.Strings.Fixed.Trim (Line (1 .. Last), Ada.Strings.Both);
      begin
         if Text'Length > 2 and then Text (Text'First .. Text'First + 1) = "0x"
         then
            return U32'Value
              ("16#" & Text (Text'First + 2 .. Text'Last) & "#");
         end if;
         return U32'Value (Text);
      end;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.End_Error | Constraint_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return 0;
   end Read_Hex_File;

   ---------------
   -- Driver_Of --
   ---------------

   function Driver_Of (Address : String) return String is
      Link : constant String := Devices_Root & "/" & Address & "/driver";
   begin
      if not Ada.Directories.Exists (Link) then
         return "";
      end if;
      return Ada.Directories.Simple_Name
        (Ada.Directories.Full_Name (Link));
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         return "";
   end Driver_Of;

   ------------
   -- Exists --
   ------------

   function Exists (Vendor : U16; Device : U16) return Boolean is
      Search : Ada.Directories.Search_Type;
      Found_Entry: Ada.Directories.Directory_Entry_Type;
      Found  : Boolean := False;
   begin
      if not Ada.Directories.Exists (Devices_Root) then
         return False;
      end if;

      Ada.Directories.Start_Search
        (Search, Devices_Root, "", (Ada.Directories.Directory => True,
                                    others => False));
      while not Found and then Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found_Entry);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Found_Entry);
            Base : constant String := Devices_Root & "/" & Name;
         begin
            if Name /= "." and then Name /= ".." then
               Found :=
                 U16 (Read_Hex_File (Base & "/vendor") and 16#FFFF#) = Vendor
                 and then
                 U16 (Read_Hex_File (Base & "/device") and 16#FFFF#) = Device;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      return Found;
   end Exists;

   ----------
   -- Find --
   ----------

   function Find (Vendor : U16; Device : U16) return String is
      Search    : Ada.Directories.Search_Type;
      Found_Entry   : Ada.Directories.Directory_Entry_Type;
      Match     : String (1 .. 32) := (others => ' ');
      Match_Len : Natural := 0;
      Other     : String (1 .. 32) := (others => ' ');
      Other_Len : Natural := 0;
      Held_By   : String (1 .. 32) := (others => ' ');
      Held_Len  : Natural := 0;
   begin
      if not Ada.Directories.Exists (Devices_Root) then
         raise Device_Not_Available with
           Devices_Root & " does not exist, so this is not a Linux host with"
           & " a PCI bus. This crate runs in the virtual machine that"
           & " scripts/qemu/run.sh boots.";
      end if;

      Ada.Directories.Start_Search
        (Search, Devices_Root, "", (Ada.Directories.Directory => True,
                                    others => False));
      while Match_Len = 0 and then Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found_Entry);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Found_Entry);
            Base : constant String := Devices_Root & "/" & Name;
         begin
            if Name /= "." and then Name /= ".."
              and then U16 (Read_Hex_File (Base & "/vendor")
                            and 16#FFFF#) = Vendor
              and then U16 (Read_Hex_File (Base & "/device")
                            and 16#FFFF#) = Device
            then
               declare
                  Driver : constant String := Driver_Of (Name);
               begin
                  if Driver = "vfio-pci" then
                     Match_Len := Name'Length;
                     Match (1 .. Match_Len) := Name;
                  else
                     Other_Len := Name'Length;
                     Other (1 .. Other_Len) := Name;
                     Held_Len := Driver'Length;
                     if Held_Len > 0 then
                        Held_By (1 .. Held_Len) := Driver;
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);

      if Match_Len > 0 then
         return Match (1 .. Match_Len);
      end if;

      if Other_Len > 0 then
         raise Device_Not_Available with
           "device " & Hex_16 (Vendor) & ":" & Hex_16 (Device) & " is at "
           & Other (1 .. Other_Len) & " but is "
           & (if Held_Len > 0
              then "bound to " & Held_By (1 .. Held_Len)
              else "not bound to any driver")
           & " rather than to vfio-pci. Binding it is not this crate's"
           & " decision: run"
           & " echo vfio-pci > " & Devices_Root & "/"
           & Other (1 .. Other_Len) & "/driver_override and then"
           & " echo " & Other (1 .. Other_Len)
           & " > /sys/bus/pci/drivers/vfio-pci/bind";
      end if;

      raise Device_Not_Available with
        "no PCI device " & Hex_16 (Vendor) & ":" & Hex_16 (Device)
        & " is present. The virtual machine scripts/qemu/run.sh boots"
        & " attaches the devices this crate drives.";
   end Find;

   ------------
   -- Hex_16 --
   ------------

   function Hex_16 (Value : U16) return String is
      Digits_16 : constant String := "0123456789abcdef";
      Result    : String (1 .. 4);
      Remaining : U16 := Value;
   begin
      for Position in reverse Result'Range loop
         Result (Position) := Digits_16 (Natural (Remaining mod 16) + 1);
         Remaining := Remaining / 16;
      end loop;
      return Result;
   end Hex_16;

   ------------
   -- Hex_32 --
   ------------

   function Hex_32 (Value : U32) return String is
      Digits_16 : constant String := "0123456789abcdef";
      Result    : String (1 .. 8);
      Remaining : U32 := Value;
   begin
      for Position in reverse Result'Range loop
         Result (Position) := Digits_16 (Natural (Remaining mod 16) + 1);
         Remaining := Remaining / 16;
      end loop;
      return Result;
   end Hex_32;

end Flyology_VFIO_QEMU;
