with Flyology_VFIO.Thin.Constants;
with Flyology_VFIO.Thin.Syscalls;
with Interfaces.C;
with System;

package body Flyology_VFIO.Interrupts is

   package C renames Interfaces.C;
   package K renames Flyology_VFIO.Thin.Constants;
   package Sys renames Flyology_VFIO.Thin.Syscalls;

   use type C.int;
   use type C.long;
   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_32;

   --  The request sent to enable or disable interrupts.
   --
   --  The C struct ends in a flexible array member, which Ada has no direct
   --  equivalent for. A fixed-size tail sized to the largest vector count
   --  this package supports is the honest substitute: the size field tells
   --  the kernel how much of it to read, so the unused remainder is never
   --  looked at. That is the same contract the flexible array gives, with
   --  the array's length decided at compile time instead of at malloc time.
   type Vector_Payload is
     array (0 .. Maximum_Vectors - 1) of Interfaces.Integer_32
     with Convention => C;

   type Set_Request is record
      Header : Thin.IRQ_Set_Header;
      Data   : Vector_Payload;
   end record
     with Convention => C;

   --  The errno a device returns for an interrupt slot it does not fill.
   Invalid_Argument : constant := 22;

   function Errno_Advice return String;

   ------------------
   -- Errno_Advice --
   ------------------

   function Errno_Advice return String is
     (" (" & Sys.Errno_Text & ")");

   --------------
   -- Describe --
   --------------

   function Describe
     (Device : Device_FD; Index : IRQ_Index) return Interrupt_Details
   is
      Info : aliased Thin.IRQ_Info :=
        (Argsz => Interfaces.Unsigned_32 (K.IRQ_Info_Size),
         Flags => 0,
         Index => Interfaces.Unsigned_32 (Index),
         Count => 0);
   begin
      if Sys.Ioctl (Sys.Raw_FD (Device.Value),
                    C.unsigned_long (K.Device_Get_IRQ_Info),
                    Info'Address) /= 0
      then
         if Sys.Errno = Invalid_Argument then
            return
              (Index            => Index,
               Implemented      => False,
               Count            => 0,
               Supports_Eventfd => False,
               Maskable         => False,
               Automasked       => False);
         end if;

         raise Interrupt_Error with
           "VFIO_DEVICE_GET_IRQ_INFO failed for index"
           & IRQ_Index'Image (Index) & Errno_Advice;
      end if;

      return
        (Index            => Index,
         Implemented      => True,
         Count            => Natural (Info.Count),
         Supports_Eventfd =>
           (Info.Flags and Interfaces.Unsigned_32 (K.IRQ_Info_Eventfd)) /= 0,
         Maskable         =>
           (Info.Flags and 2) /= 0,
         Automasked       =>
           (Info.Flags and 4) /= 0);
   end Describe;

   ----------
   -- Open --
   ----------

   procedure Open (Self : in out Event) is
      Raw : constant Sys.Raw_FD :=
        Sys.Eventfd (0,
                     C.int (K.Eventfd_Cloexec) + C.int (K.Eventfd_Nonblock));
   begin
      if Raw < 0 then
         if not Sys.Platform_Supports_VFIO then
            raise Interrupt_Error with
              "this platform has no eventfd, and no VFIO for it to deliver"
              & " interrupts from. Interrupt delivery is Linux-only.";
         end if;
         raise Interrupt_Error with
           "eventfd could not be created" & Errno_Advice;
      end if;
      Self.Value := Integer (Raw);
   end Open;

   ----------
   -- Take --
   ----------

   function Take (Self : Event) return Interfaces.Unsigned_64 is
      function C_Read
        (FD : C.int; Buffer : System.Address; Count : C.size_t) return C.long
        with Import, Convention => C, External_Name => "read";

      Counter : aliased Interfaces.Unsigned_64 := 0;
      Got     : constant C.long :=
        C_Read (C.int (Self.Value), Counter'Address, 8);
   begin
      --  A non-blocking eventfd with nothing pending fails with EAGAIN,
      --  which is the ordinary case rather than an error.
      if Got /= 8 then
         return 0;
      end if;
      return Counter;
   end Take;

   -----------
   -- Close --
   -----------

   procedure Close (Self : in out Event) is
   begin
      if Self.Value >= 0 then
         Sys.Close (Sys.Raw_FD (Self.Value));
         Self.Value := -1;
      end if;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Event) is
   begin
      Close (Self);
   end Finalize;

   ------------
   -- Enable --
   ------------

   procedure Enable
     (Device  : Device_FD;
      Index   : IRQ_Index;
      Vectors : Vector_Descriptors)
   is
      Count   : constant Interfaces.Unsigned_32 := Vectors'Length;
      Request : aliased Set_Request :=
        (Header =>
           (--  Head plus one descriptor per vector, and nothing more. The
            --  kernel checks this against the count and the flags, so an
            --  arithmetic slip here is rejected rather than misread.
            Argsz => Interfaces.Unsigned_32 (K.IRQ_Set_Header_Size)
                     + 4 * Count,
            Flags => Interfaces.Unsigned_32 (K.IRQ_Set_Data_Eventfd)
                     or Interfaces.Unsigned_32 (K.IRQ_Set_Action_Trigger),
            Index => Interfaces.Unsigned_32 (Index),
            Start => 0,
            Count => Count),
         Data   => (others => -1));
      Slot : Natural := 0;
   begin
      for Descriptor of Vectors loop
         Request.Data (Slot) := Interfaces.Integer_32 (Descriptor);
         Slot := Slot + 1;
      end loop;

      if Sys.Ioctl (Sys.Raw_FD (Device.Value),
                    C.unsigned_long (K.Device_Set_IRQs),
                    Request'Address) /= 0
      then
         raise Interrupt_Error with
           "VFIO_DEVICE_SET_IRQS failed enabling"
           & Interfaces.Unsigned_32'Image (Count) & " vector(s) on index"
           & IRQ_Index'Image (Index) & Errno_Advice
           & ". Check that the index exists and offers at least that many"
           & " vectors: Describe reports both.";
      end if;
   end Enable;

   -------------
   -- Disable --
   -------------

   procedure Disable (Device : Device_FD; Index : IRQ_Index) is
      --  Disabling carries no tail at all, so the size is the head alone
      --  and the flags say there is no data.
      Request : aliased Thin.IRQ_Set_Header :=
        (Argsz => Interfaces.Unsigned_32 (K.IRQ_Set_Header_Size),
         Flags => Interfaces.Unsigned_32 (K.IRQ_Set_Data_None)
                  or Interfaces.Unsigned_32 (K.IRQ_Set_Action_Trigger),
         Index => Interfaces.Unsigned_32 (Index),
         Start => 0,
         Count => 0);
   begin
      if Sys.Ioctl (Sys.Raw_FD (Device.Value),
                    C.unsigned_long (K.Device_Set_IRQs),
                    Request'Address) /= 0
      then
         raise Interrupt_Error with
           "VFIO_DEVICE_SET_IRQS failed disabling index"
           & IRQ_Index'Image (Index) & Errno_Advice;
      end if;
   end Disable;

end Flyology_VFIO.Interrupts;
