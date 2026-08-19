with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;

package body Flyology_VFIO_QEMU is

   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   Devices_Root : constant String := "/sys/bus/pci/devices";

   --  A PCI address is domain:bus:device.function, twelve characters.
   Maximum_Address_Length : constant := 16;

   --  More instances of one device than any test here attaches.
   Maximum_Instances : constant := 8;

   type Length_List is array (Positive range <>) of Natural;

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

   function Driver_Of (Address : PCI_Address) return String is
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

   ----------------------
   -- Matching_Devices --
   ----------------------

   --  Collects the addresses of every device with this identity, sorted, so
   --  that "the second edu" means the same device from one run to the next.
   --  Sorting matters more than it looks: PCI addresses come back from a
   --  directory listing in whatever order the filesystem gives, and a test
   --  that maps two devices differently on different runs is a test whose
   --  failures cannot be reproduced.
   type Address_List is
     array (Positive range <>) of String (1 .. Maximum_Address_Length);

   procedure Matching_Devices
     (Vendor    : U16;
      Device    : U16;
      Addresses : out Address_List;
      Lengths   : out Length_List;
      Bound     : out Natural;
      Unbound   : out Natural;
      Example   : out String;
      Example_N : out Natural)
   is
      Search       : Ada.Directories.Search_Type;
      Found_Entry  : Ada.Directories.Directory_Entry_Type;
   begin
      Bound := 0;
      Unbound := 0;
      Example_N := 0;
      Addresses := (others => (others => ' '));
      Lengths := (others => 0);

      if not Ada.Directories.Exists (Devices_Root) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search, Devices_Root, "", (Ada.Directories.Directory => True,
                                    others => False));
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found_Entry);
         declare
            Name : constant String :=
              Ada.Directories.Simple_Name (Found_Entry);
            Base : constant String := Devices_Root & "/" & Name;
         begin
            if Name /= "." and then Name /= ".."
              and then Name'Length <= Maximum_Address_Length
              and then U16 (Read_Hex_File (Base & "/vendor")
                            and 16#FFFF#) = Vendor
              and then U16 (Read_Hex_File (Base & "/device")
                            and 16#FFFF#) = Device
            then
               if Driver_Of (Name) = "vfio-pci" then
                  if Bound < Addresses'Length then
                     Bound := Bound + 1;
                     Addresses (Bound) (1 .. Name'Length) := Name;
                     Lengths (Bound) := Name'Length;
                  end if;
               else
                  Unbound := Unbound + 1;
                  if Example_N = 0
                    and then Name'Length <= Example'Length
                  then
                     Example_N := Name'Length;
                     Example (Example'First .. Example'First + Example_N - 1)
                       := Name;
                  end if;
               end if;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);

      --  An insertion sort over at most a handful of entries.
      for Outer in 2 .. Bound loop
         declare
            Key_Address : constant String (1 .. Maximum_Address_Length) :=
              Addresses (Outer);
            Key_Length  : constant Natural := Lengths (Outer);
            Inner       : Natural := Outer - 1;
         begin
            while Inner >= 1
              and then Addresses (Inner) > Key_Address
            loop
               Addresses (Inner + 1) := Addresses (Inner);
               Lengths (Inner + 1) := Lengths (Inner);
               Inner := Inner - 1;
            end loop;
            Addresses (Inner + 1) := Key_Address;
            Lengths (Inner + 1) := Key_Length;
         end;
      end loop;
   end Matching_Devices;

   ---------------
   -- Available --
   ---------------

   function Available (Vendor : U16; Device : U16) return Natural is
      Addresses : Address_List (1 .. Maximum_Instances);
      Lengths   : Length_List (1 .. Maximum_Instances);
      Bound     : Natural;
      Unbound   : Natural;
      Example   : String (1 .. Maximum_Address_Length);
      Example_N : Natural;
   begin
      Matching_Devices
        (Vendor, Device, Addresses, Lengths, Bound, Unbound,
         Example, Example_N);
      return Bound;
   end Available;

   ----------
   -- Find --
   ----------

   function Find
     (Vendor : U16; Device : U16; Instance : Positive := 1)
      return PCI_Address
   is
      Addresses : Address_List (1 .. Maximum_Instances);
      Lengths   : Length_List (1 .. Maximum_Instances);
      Bound     : Natural;
      Unbound   : Natural;
      Example   : String (1 .. Maximum_Address_Length);
      Example_N : Natural;
   begin
      if not Ada.Directories.Exists (Devices_Root) then
         raise Device_Not_Available with
           Devices_Root & " does not exist, so this is not a Linux host with"
           & " a PCI bus. This crate runs in the virtual machine that"
           & " scripts/qemu/run.sh boots.";
      end if;

      Matching_Devices
        (Vendor, Device, Addresses, Lengths, Bound, Unbound,
         Example, Example_N);

      if Instance <= Bound then
         return Addresses (Instance) (1 .. Lengths (Instance));
      end if;

      if Bound > 0 then
         raise Device_Not_Available with
           "only" & Natural'Image (Bound) & " device(s)"
           & Hex_16 (Vendor) & ":" & Hex_16 (Device)
           & " are bound to vfio-pci, and instance"
           & Positive'Image (Instance) & " was asked for. The virtual"
           & " machine attaches more than one of some devices precisely so"
           & " that a container holding several groups can be tested.";
      end if;

      if Unbound > 0 then
         raise Device_Not_Available with
           "device " & Hex_16 (Vendor) & ":" & Hex_16 (Device) & " is"
           & " present" & (if Example_N > 0
                           then " at " & Example (1 .. Example_N) else "")
           & " but is not bound to vfio-pci. Binding it is not this crate's"
           & " decision: unbind it from its driver, then"
           & " echo vfio-pci > /sys/bus/pci/devices/<address>/driver_override"
           & " and echo <address> > /sys/bus/pci/drivers/vfio-pci/bind";
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
