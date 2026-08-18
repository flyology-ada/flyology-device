with Interfaces.C;
use type Interfaces.C.int;
with System;

--  The system calls this crate makes, and the three shapes a VFIO ioctl
--  comes in.
--
--  VFIO ioctls are not uniform, which is easy to miss because most of them
--  are. Three take no argument at all, three take a bare integer or string,
--  and the rest take a struct whose first field is its own size. Binding
--  them all through one pointer-shaped import would compile and would send
--  the kernel a pointer where it expected an integer.
--
--  ioctl is variadic in C. Each shape is imported separately with the exact
--  profile it is called with, which is what the ABI requires and what makes
--  the difference visible in the source.
--  Preelaborate so that the root package, which is itself preelaborated,
--  can close descriptors from its own body.
package Flyology_VFIO.Thin.Syscalls
  with Preelaborate
is

   package C renames Interfaces.C;

   --  A raw descriptor as the C library takes it.
   subtype Raw_FD is C.int;

   --  Not a descriptor.
   Invalid : constant Raw_FD := -1;

   --  Opens a path for reading and writing, close-on-exec.
   --  @param Path The path to open, without a terminating NUL
   --  @return The descriptor, or Invalid with errno set
   function Open_Read_Write (Path : String) return Raw_FD;

   --  Closes a descriptor, ignoring the result.
   --
   --  Nothing useful can be done with a failing close: the descriptor is
   --  gone either way, and on Linux it is gone even when close reports an
   --  error. Reporting it would only add noise to teardown.
   --
   --  @param FD The descriptor to close
   procedure Close (FD : Raw_FD);

   --  An ioctl taking no argument.
   --  @param FD The descriptor
   --  @param Request The request number
   --  @return The kernel's result, or -1 with errno set
   function Ioctl (FD : Raw_FD; Request : C.unsigned_long) return C.int
     with Import, Convention => C, External_Name => "ioctl";

   --  An ioctl whose argument is a plain integer, such as an IOMMU type or
   --  a container descriptor.
   --  @param FD The descriptor
   --  @param Request The request number
   --  @param Argument The integer argument
   --  @return The kernel's result, or -1 with errno set
   function Ioctl
     (FD       : Raw_FD;
      Request  : C.unsigned_long;
      Argument : C.int) return C.int
     with Import, Convention => C, External_Name => "ioctl";

   --  An ioctl whose argument is a pointer: an argsz struct, or the
   --  NUL-terminated device name that VFIO_GROUP_GET_DEVICE_FD takes.
   --  @param FD The descriptor
   --  @param Request The request number
   --  @param Argument Address of the argument
   --  @return The kernel's result, or -1 with errno set
   function Ioctl
     (FD       : Raw_FD;
      Request  : C.unsigned_long;
      Argument : System.Address) return C.int
     with Import, Convention => C, External_Name => "ioctl";

   --  Reads from a descriptor at an absolute offset.
   --
   --  This is how configuration space is read: that region is never
   --  mappable, so it is reached with pread and pwrite at the offset the
   --  region info reports.
   --
   --  @param FD The descriptor
   --  @param Buffer Address of the destination
   --  @param Count Bytes to read
   --  @param Offset Absolute offset within the descriptor
   --  @return Bytes read, or -1 with errno set
   function Pread
     (FD     : Raw_FD;
      Buffer : System.Address;
      Count  : C.size_t;
      Offset : C.long) return C.long
     with Import, Convention => C, External_Name => "pread";

   --  Writes to a descriptor at an absolute offset.
   --  @param FD The descriptor
   --  @param Buffer Address of the source
   --  @param Count Bytes to write
   --  @param Offset Absolute offset within the descriptor
   --  @return Bytes written, or -1 with errno set
   function Pwrite
     (FD     : Raw_FD;
      Buffer : System.Address;
      Count  : C.size_t;
      Offset : C.long) return C.long
     with Import, Convention => C, External_Name => "pwrite";

   --  Maps part of a descriptor into the process.
   --  @param Addr Preferred address, or Null_Address for any
   --  @param Length Bytes to map
   --  @param Prot Protection bits
   --  @param Flags Mapping flags
   --  @param FD The descriptor to map from
   --  @param Offset Offset within the descriptor
   --  @return The mapping's address, or the failure sentinel
   function Mmap
     (Addr   : System.Address;
      Length : C.size_t;
      Prot   : C.int;
      Flags  : C.int;
      FD     : Raw_FD;
      Offset : C.long) return System.Address
     with Import, Convention => C, External_Name => "mmap";

   --  Releases a mapping.
   --  @param Addr The mapping's address
   --  @param Length The mapping's length
   --  @return Zero, or -1 with errno set
   function Munmap (Addr : System.Address; Length : C.size_t) return C.int
     with Import, Convention => C, External_Name => "munmap";

   --  Creates an eventfd, which is how VFIO delivers an interrupt.
   --
   --  Linux only. It is a function with a body per platform rather than a
   --  direct import because eventfd does not exist on Darwin, and a direct
   --  import would leave every Darwin link failing on an undefined symbol
   --  rather than the crate simply reporting that this host has no VFIO.
   --
   --  @param Initial Initial counter value
   --  @param Flags Creation flags
   --  @return The descriptor, or -1 with errno set
   function Eventfd (Initial : C.unsigned; Flags : C.int) return Raw_FD;

   --  Whether this platform has the interfaces this crate needs at all.
   --
   --  False on Darwin, where VFIO does not exist. The crate still builds
   --  and its host-independent tests still run; what it cannot do is open a
   --  device.
   --  @return True on Linux
   function Platform_Supports_VFIO return Boolean;

   --  The current errno, and a sentence describing it.
   --  @return A string of the form "errno 22 (Invalid argument)"
   function Errno_Text return String;

   --  The current errno as a number, for callers that distinguish cases.
   --  @return The C errno value
   function Errno return Integer;

end Flyology_VFIO.Thin.Syscalls;
