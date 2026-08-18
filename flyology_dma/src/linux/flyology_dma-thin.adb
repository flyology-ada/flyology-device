with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_DMA.Thin is

   use type Interfaces.C.int;
   use type System.Address;
   use type System.Storage_Elements.Integer_Address;

   package C renames Interfaces.C;

   --  These are the Linux values for x86-64 and aarch64. MAP_ANONYMOUS in
   --  particular is not the same number on every Linux architecture; alpha
   --  and mips use 0x800. scripts/verify-constants.sh checks all of them
   --  against the kernel headers of the build host, so a port to another
   --  architecture fails the check rather than mapping the wrong thing.
   --  Ada identifiers are case-insensitive, so these cannot carry their
   --  kernel names unchanged: MAP_ANONYMOUS and Map_Anonymous would be one
   --  identifier. Each carries its kernel name in a trailing comment, which
   --  is what scripts/verify-constants.sh matches against the headers of a
   --  Linux host.
   Prot_Read      : constant C.int := 1;            --  PROT_READ
   Prot_Write     : constant C.int := 2;            --  PROT_WRITE
   Flag_Private   : constant C.int := 2;            --  MAP_PRIVATE
   Flag_Anonymous : constant C.int := 16#20#;       --  MAP_ANONYMOUS
   Flag_Populate  : constant C.int := 16#8000#;     --  MAP_POPULATE
   Flag_Hugetlb   : constant C.int := 16#4_0000#;   --  MAP_HUGETLB

   --  The huge page size is encoded as log2 of the size shifted into the
   --  flags word: MAP_HUGE_2MB is 21 << 26 and MAP_HUGE_1GB is 30 << 26.
   Flag_Huge_2MB  : constant C.int := 21 * 2 ** 26; --  MAP_HUGE_2MB
   Flag_Huge_1GB  : constant C.int := 30 * 2 ** 26; --  MAP_HUGE_1GB

   Memlock_Limit  : constant C.int := 8;            --  RLIMIT_MEMLOCK
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

   Sc_Pagesize : constant C.int := 30;  --  _SC_PAGESIZE

   type Rlimit is record
      Soft : Interfaces.Unsigned_64;
      Hard : Interfaces.Unsigned_64;
   end record
     with Convention => C;

   function C_Getrlimit (Resource : C.int; Limit : access Rlimit) return C.int
     with Import, Convention => C, External_Name => "getrlimit";

   --  Reads one integer from a sysfs or procfs file, returning Default when
   --  the file is absent or does not hold an integer. Every caller is
   --  reporting on host configuration, where an unreadable file and a zero
   --  mean the same thing to the operator.
   function Read_Integer_File (Path : String; Default : Integer := 0)
     return Integer;

   function Hugepage_Directory (Backing : Region_Backing) return String;

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

   -----------------------
   -- Read_Integer_File --
   -----------------------

   function Read_Integer_File (Path : String; Default : Integer := 0)
     return Integer
   is
      File : Ada.Text_IO.File_Type;
      Line : String (1 .. 64);
      Last : Natural;
   begin
      if not Ada.Directories.Exists (Path) then
         return Default;
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      Ada.Text_IO.Get_Line (File, Line, Last);
      Ada.Text_IO.Close (File);
      return Integer'Value (Line (1 .. Last));
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.End_Error | Constraint_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return Default;
   end Read_Integer_File;

   ------------------------
   -- Hugepage_Directory --
   ------------------------

   function Hugepage_Directory (Backing : Region_Backing) return String is
   begin
      case Backing is
         when Huge_2M =>
            return "/sys/kernel/mm/hugepages/hugepages-2048kB";
         when Huge_1G =>
            return "/sys/kernel/mm/hugepages/hugepages-1048576kB";
         when Regular_Pages =>
            return "";
      end case;
   end Hugepage_Directory;

   --------------
   -- Supports --
   --------------

   function Supports (Backing : Region_Backing) return Boolean is
     (case Backing is
         when Regular_Pages => True,
         when Huge_2M | Huge_1G =>
            Ada.Directories.Exists (Hugepage_Directory (Backing)));

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

   -------------------------
   -- Unsupported_Reason --
   -------------------------

   function Unsupported_Reason (Backing : Region_Backing) return String is
   begin
      if Supports (Backing) then
         return "";
      end if;
      return "this kernel has no pool of this size: "
        & Hugepage_Directory (Backing)
        & " is absent, which means it was built without hugetlbfs or"
        & " without this page size. Boot a kernel with CONFIG_HUGETLBFS,"
        & " or use Regular_Pages.";
   end Unsupported_Reason;

   ---------------------
   -- Hugepages_Free --
   ---------------------

   function Hugepages_Free (Backing : Region_Backing) return Natural is
   begin
      if Backing = Regular_Pages then
         return 0;
      end if;
      return Natural'Max
        (0, Read_Integer_File (Hugepage_Directory (Backing) & "/free_hugepages"));
   end Hugepages_Free;

   ----------------------
   -- Hugepages_Total --
   ----------------------

   function Hugepages_Total (Backing : Region_Backing) return Natural is
   begin
      if Backing = Regular_Pages then
         return 0;
      end if;
      return Natural'Max
        (0, Read_Integer_File (Hugepage_Directory (Backing) & "/nr_hugepages"));
   end Hugepages_Total;

   -------------------------
   -- Memory_Lock_Limit --
   -------------------------

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
      Flags  : C.int := Flag_Private + Flag_Anonymous;
      Result : System.Address;
   begin
      if not Supports (Backing) then
         raise Hugepage_Unavailable with
           "this kernel has no " & Region_Backing'Image (Backing)
           & " hugepage pool: " & Hugepage_Directory (Backing)
           & " is absent, which means the kernel was built without"
           & " hugetlbfs or without this page size. Boot a kernel with"
           & " CONFIG_HUGETLBFS, or request Regular_Pages explicitly.";
      end if;

      --  Populate eagerly, and never MAP_NORESERVE. A region that faults in
      --  lazily turns a shortage of memory into a fault at the first device
      --  write, which is both far from the cause and, once a device is
      --  running, not recoverable. Hugetlb mappings already reserve at mmap
      --  time; populating as well costs nothing and keeps the two paths
      --  behaving alike.
      Flags := Flags + Flag_Populate;

      case Backing is
         when Huge_2M =>
            Flags := Flags + Flag_Hugetlb + Flag_Huge_2MB;
         when Huge_1G =>
            Flags := Flags + Flag_Hugetlb + Flag_Huge_1GB;
         when Regular_Pages =>
            null;
      end case;

      Result := C_Mmap
        (Addr   => System.Null_Address,
         Length => C.size_t (Length),
         Prot   => Prot_Read + Prot_Write,
         Flags  => Flags,
         Fd     => -1,
         Offset => 0);

      if Result = Map_Failed then
         if Backing /= Regular_Pages then
            raise Hugepage_Unavailable with
              "could not map" & Byte_Count'Image (Length) & " bytes of "
              & Region_Backing'Image (Backing) & " hugepages ("
              & Errno_Text & "). The pool holds"
              & Natural'Image (Hugepages_Free (Backing)) & " free of"
              & Natural'Image (Hugepages_Total (Backing))
              & " pages. Reserve more with: echo N > "
              & Hugepage_Directory (Backing) & "/nr_hugepages"
              & " (1 GiB pages usually need hugepagesz=1G hugepages=N on the"
              & " kernel command line instead).";
         end if;
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
                 & ". Raise it with: ulimit -l <kibibytes>, or grant"
                 & " CAP_IPC_LOCK. DMA memory must stay resident because a"
                 & " device writes to it without the kernel's knowledge.";
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
