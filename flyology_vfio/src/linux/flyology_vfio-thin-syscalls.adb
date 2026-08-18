with Flyology_VFIO.Thin.Constants;
with GNAT.OS_Lib;

package body Flyology_VFIO.Thin.Syscalls is

   function C_Open
     (Path  : C.char_array;
      Flags : C.int;
      Mode  : C.int := 0) return Raw_FD
     with Import, Convention => C, External_Name => "open";

   procedure C_Close (FD : Raw_FD)
     with Import, Convention => C, External_Name => "close";

   -----------------------
   -- Open_Read_Write --
   -----------------------

   function Open_Read_Write (Path : String) return Raw_FD is
      Flags : constant C.int :=
        C.int (Constants.Open_Read_Write) + C.int (Constants.Open_Cloexec);
   begin
      return C_Open (C.To_C (Path), Flags);
   end Open_Read_Write;

   -----------
   -- Close --
   -----------

   procedure Close (FD : Raw_FD) is
   begin
      if FD /= Invalid then
         C_Close (FD);
      end if;
   end Close;

   -------------
   -- Eventfd --
   -------------

   function C_Eventfd (Initial : C.unsigned; Flags : C.int) return Raw_FD
     with Import, Convention => C, External_Name => "eventfd";

   function Eventfd (Initial : C.unsigned; Flags : C.int) return Raw_FD is
     (C_Eventfd (Initial, Flags));

   ------------------------------
   -- Platform_Supports_VFIO --
   ------------------------------

   function Platform_Supports_VFIO return Boolean is (True);

   -----------
   -- Errno --
   -----------

   function Errno return Integer is (GNAT.OS_Lib.Errno);

   ----------------
   -- Errno_Text --
   ----------------

   function Errno_Text return String is
      Code : constant Integer := GNAT.OS_Lib.Errno;
   begin
      return "errno" & Integer'Image (Code) & " ("
        & GNAT.OS_Lib.Errno_Message (Err => Code) & ")";
   end Errno_Text;

end Flyology_VFIO.Thin.Syscalls;
