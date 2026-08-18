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
   use type Sys.Poll_Flags;
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

   --  The errno poll reports when a signal arrived before anything was
   --  ready. It is not a failure and the wait must be resumed.
   Interrupted_System_Call : constant := 4;

   function Errno_Advice return String;

   ------------------
   -- Errno_Advice --
   ------------------

   function Errno_Advice return String is
     (" (" & Sys.Errno_Text & ")");

   ---------------------
   -- Timeout_Millis --
   ---------------------

   --  poll counts milliseconds and reads a negative value as no limit,
   --  which is the convention this crate adopted rather than inventing a
   --  second one. Rounding up matters: a caller asking for a tenth of a
   --  millisecond wants to wait a little, not to spin.
   function Timeout_Millis (Timeout : Duration) return C.int is
   begin
      if Timeout < 0.0 then
         return -1;
      end if;
      --  Spelled through Long_Float rather than fixed-point arithmetic,
      --  which Ada would otherwise resolve to Duration and warn about.
      return C.int
        (Long_Float'Ceiling
           (Long_Float (Duration'Min (Timeout, 86_400.0)) * 1_000.0));
   end Timeout_Millis;

   --------------
   -- Wait_For --
   --------------

   overriding function Wait_For
     (Self    : in out Blocking_Waiter;
      Signal  : Event'Class;
      Timeout : Duration) return Boolean
   is
      pragma Unreferenced (Self);
      Watched : constant Descriptor_Array := [1 => Descriptor (Signal)];
      Blocking : Blocking_Waiter;
   begin
      return Wait_For_Any (Blocking, Watched, Timeout) = 1;
   end Wait_For;

   ------------------
   -- Wait_For_Any --
   ------------------

   overriding function Wait_For_Any
     (Self    : in out Blocking_Waiter;
      Signals : Descriptor_Array;
      Timeout : Duration) return Natural
   is
      pragma Unreferenced (Self);

      Requests : Sys.Poll_Request_Array (Signals'Range);
      Ready    : C.int;
   begin
      if Signals'Length = 0 then
         return 0;
      end if;

      for Index in Signals'Range loop
         Requests (Index) :=
           (FD      => Sys.Raw_FD (Signals (Index)),
            Events  => Sys.Poll_Readable,
            Revents => 0);
      end loop;

      --  A single deadline is not maintained across retries here, so an
      --  interrupted wait restarts its timeout. That is a real difference
      --  from Flyology.IO.Wait, which carries one deadline across EINTR,
      --  and it is one of the reasons a program that has the runtime
      --  should use the waiter in flyology_vfio_runtime instead of this.
      loop
         Ready := Sys.Poll
           (Requests (Requests'First)'Address,
            C.unsigned_long (Signals'Length),
            Timeout_Millis (Timeout));

         exit when Ready >= 0;
         if Sys.Errno /= Interrupted_System_Call then
            raise Interrupt_Error with
              "waiting on" & Natural'Image (Signals'Length)
              & " interrupt descriptor(s) failed" & Errno_Advice;
         end if;
      end loop;

      if Ready = 0 then
         return 0;
      end if;

      --  The lowest index wins, so a caller can order its descriptors by
      --  what it would rather service first.
      for Index in Requests'Range loop
         if (Requests (Index).Revents and Sys.Poll_Readable) /= 0 then
            return Index;
         end if;
      end loop;

      --  Something became ready in a way that was not asked for: the
      --  descriptor has been closed, or is not one.
      raise Interrupt_Error with
        "an interrupt descriptor reported an error rather than becoming"
        & " readable, which usually means it has been closed";
   end Wait_For_Any;

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

   --  Mask and unmask carry no data tail, exactly like Disable: the index
   --  and the action are the whole request.
   procedure Set_Mask_State
     (Device : Device_FD; Index : IRQ_Index; Action : Interfaces.Unsigned_32;
      Verb   : String);

   ---------------------
   -- Set_Mask_State --
   ---------------------

   procedure Set_Mask_State
     (Device : Device_FD; Index : IRQ_Index; Action : Interfaces.Unsigned_32;
      Verb   : String)
   is
      Request : aliased Thin.IRQ_Set_Header :=
        (Argsz => Interfaces.Unsigned_32 (K.IRQ_Set_Header_Size),
         Flags => Interfaces.Unsigned_32 (K.IRQ_Set_Data_None) or Action,
         Index => Interfaces.Unsigned_32 (Index),
         Start => 0,
         Count => 1);
   begin
      if Sys.Ioctl (Sys.Raw_FD (Device.Value),
                    C.unsigned_long (K.Device_Set_IRQs),
                    Request'Address) /= 0
      then
         raise Interrupt_Error with
           "VFIO_DEVICE_SET_IRQS failed " & Verb & " index"
           & IRQ_Index'Image (Index) & Errno_Advice;
      end if;
   end Set_Mask_State;

   ------------
   -- Unmask --
   ------------

   procedure Unmask (Device : Device_FD; Index : IRQ_Index) is
   begin
      Set_Mask_State
        (Device, Index,
         Interfaces.Unsigned_32 (K.IRQ_Set_Action_Unmask), "unmasking");
   end Unmask;

   ----------
   -- Mask --
   ----------

   procedure Mask (Device : Device_FD; Index : IRQ_Index) is
   begin
      Set_Mask_State
        (Device, Index,
         Interfaces.Unsigned_32 (K.IRQ_Set_Action_Mask), "masking");
   end Mask;

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
