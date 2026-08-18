with GNAT.OS_Lib;
with Interfaces.C;
with System.Storage_Elements;

--  Darwin body for the host memory syscalls.
--
--  Darwin exists here so that the portable units — the IOVA allocator, the
--  pools, the identity mapper, and everything built on them — can be built
--  and tested on a development host. It is not a target for driver work:
--  there is no hugetlbfs, no MAP_HUGETLB, and no VFIO, and asking for a
--  hugepage backing raises rather than quietly returning ordinary pages.
package body Flyology_DMA.Thin is

   use type Interfaces.C.int;
   use type System.Address;
   use type System.Storage_Elements.Integer_Address;

   package C renames Interfaces.C;

   --  Named like the Linux body's constants, and for the same reason: Ada
   --  identifiers are case-insensitive, so MAP_ANON could not sit beside
   --  Map_Anonymous. Kernel names are in the trailing comments.
   Prot_Read      : constant C.int := 1;      --  PROT_READ
   Prot_Write     : constant C.int := 2;      --  PROT_WRITE
   Flag_Private   : constant C.int := 2;      --  MAP_PRIVATE
   Flag_Anonymous : constant C.int := 16#1000#;  --  MAP_ANON

   Memlock_Limit  : constant C.int := 6;      --  RLIMIT_MEMLOCK
   RLIM_INFINITY  : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64'Last;

   Map_Failed : constant System.Address :=
     System.Storage_Elements.To_Address (-1);

   function C_Mmap
     (Addr   : System.Address;
      Length : C.size_t;
      Prot   : C.int;
      Flags  : C.int;
      Fd     : C.int;
      Offset : C.long) return System.Address
     with Import, Convention => C, External_Name => "mmap";

   function C_Munmap (Addr : System.Address; Length : C.size_t) return C.int
     with Import, Convention => C, External_Name => "munmap";

   function C_Mlock (Addr : System.Address; Length : C.size_t) return C.int
     with Import, Convention => C, External_Name => "mlock";

   function C_Sysconf (Name : C.int) return C.long
     with Import, Convention => C, External_Name => "sysconf";

   Sc_Pagesize : constant C.int := 29;  --  _SC_PAGESIZE

   type Rlimit is record
      Soft : Interfaces.Unsigned_64;
      Hard : Interfaces.Unsigned_64;
   end record
     with Convention => C;

   function C_Getrlimit (Resource : C.int; Limit : access Rlimit) return C.int
     with Import, Convention => C, External_Name => "getrlimit";

   function Errno_Text return String;

   ----------------
   -- Errno_Text --
   ----------------

   function Errno_Text return String is
      Code : constant Integer := GNAT.OS_Lib.Errno;
   begin
      return "errno" & Integer'Image (Code) & " ("
        & GNAT.OS_Lib.Errno_Message (Err => Code) & ")";
   end Errno_Text;

   --------------
   -- Supports --
   --------------

   function Supports (Backing : Region_Backing) return Boolean is
     (Backing = Regular_Pages);

   ---------------
   -- Page_Size --
   ---------------

   function Page_Size (Backing : Region_Backing) return Byte_Count is
   begin
      case Backing is
         when Huge_2M =>
            return 2 * 1024 * 1024;
         when Huge_1G =>
            return 1024 * 1024 * 1024;
         when Regular_Pages =>
            return Byte_Count (C_Sysconf (Sc_Pagesize));
      end case;
   end Page_Size;

   ------------------------
   -- Unsupported_Reason --
   ------------------------

   function Unsupported_Reason (Backing : Region_Backing) return String is
   begin
      if Supports (Backing) then
         return "";
      end if;
      return "Darwin has no hugetlbfs and no equivalent, so no hugepage"
        & " backing is available on this host at all. Darwin builds exist"
        & " to exercise the portable units during development; run the"
        & " hugepage tests on Linux.";
   end Unsupported_Reason;

   --------------------
   -- Hugepages_Free --
   --------------------

   function Hugepages_Free (Backing : Region_Backing) return Natural is
      pragma Unreferenced (Backing);
   begin
      return 0;
   end Hugepages_Free;

   ---------------------
   -- Hugepages_Total --
   ---------------------

   function Hugepages_Total (Backing : Region_Backing) return Natural is
      pragma Unreferenced (Backing);
   begin
      return 0;
   end Hugepages_Total;

   -----------------------
   -- Memory_Lock_Limit --
   -----------------------

   function Memory_Lock_Limit return Byte_Count is
      Limit : aliased Rlimit;
      use type Interfaces.Unsigned_64;
   begin
      if C_Getrlimit (Memlock_Limit, Limit'Access) /= 0 then
         return 0;
      end if;
      if Limit.Soft = RLIM_INFINITY
        or else Limit.Soft > Interfaces.Unsigned_64 (Byte_Count'Last)
      then
         return Byte_Count'Last;
      end if;
      return Byte_Count (Limit.Soft);
   end Memory_Lock_Limit;

   -------------------
   -- Map_Anonymous --
   -------------------

   function Map_Anonymous
     (Length  : Byte_Count;
      Backing : Region_Backing;
      Lock    : Boolean) return System.Address
   is
      Result : System.Address;
   begin
      if not Supports (Backing) then
         raise Hugepage_Unavailable with
           "Darwin has no hugetlbfs, so " & Region_Backing'Image (Backing)
           & " cannot be backed here. Darwin builds exist to exercise the"
           & " portable units on a development host; request Regular_Pages,"
           & " or run the hugepage tests on Linux.";
      end if;

      Result := C_Mmap
        (Addr   => System.Null_Address,
         Length => C.size_t (Length),
         Prot   => Prot_Read + Prot_Write,
         Flags  => Flag_Private + Flag_Anonymous,
         Fd     => -1,
         Offset => 0);

      if Result = Map_Failed then
         raise Region_Error with
           "mmap of" & Byte_Count'Image (Length) & " bytes failed ("
           & Errno_Text & ")";
      end if;

      if Lock then
         if C_Mlock (Result, C.size_t (Length)) /= 0 then
            declare
               Reason : constant String := Errno_Text;
               Limit  : constant Byte_Count := Memory_Lock_Limit;
            begin
               if C_Munmap (Result, C.size_t (Length)) /= 0 then
                  null;  --  The mlock failure is the one worth reporting.
               end if;
               raise Memory_Lock_Failed with
                 "could not lock" & Byte_Count'Image (Length)
                 & " bytes into RAM (" & Reason & "). RLIMIT_MEMLOCK is"
                 & (if Limit = Byte_Count'Last then " unlimited"
                    else Byte_Count'Image (Limit) & " bytes")
                 & ". Raise it with: ulimit -l <kibibytes>.";
            end;
         end if;
      end if;

      return Result;
   end Map_Anonymous;

   -----------
   -- Unmap --
   -----------

   procedure Unmap (Base : System.Address; Length : Byte_Count) is
   begin
      if C_Munmap (Base, C.size_t (Length)) /= 0 then
         raise Region_Error with
           "munmap of" & Byte_Count'Image (Length) & " bytes failed ("
           & Errno_Text & ")";
      end if;
   end Unmap;

end Flyology_DMA.Thin;
