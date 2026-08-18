with Flyology_VFIO.Registers;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_VFIO_QEMU.NVMe is

   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type SSE.Storage_Offset;

   procedure Wait_Microseconds (Count : Interfaces.C.unsigned)
     with Import, Convention => C, External_Name => "usleep";

   --  Bytes of a queue or data structure, addressed one at a time.
   --
   --  Volatile because a controller writes them by DMA, with nothing in the
   --  program to tell the optimiser that memory it watched being written
   --  can change again before it is read.
   type Byte_Array is array (Natural range <>) of U8 with Volatile;

   procedure Put_64 (Base : System.Address; At_Offset : Natural; Value : U64);
   procedure Put_32 (Base : System.Address; At_Offset : Natural; Value : U32);
   procedure Put_16 (Base : System.Address; At_Offset : Natural; Value : U16);
   function Get_16 (Base : System.Address; At_Offset : Natural) return U16;

   ------------
   -- Put_64 --
   ------------

   --  Written a byte at a time rather than through an overlay of the whole
   --  value. A queue entry is a little-endian byte layout defined by a
   --  specification, and spelling it out byte by byte keeps it correct on a
   --  big-endian host, where an overlay would silently reverse it.

   procedure Put_64 (Base : System.Address; At_Offset : Natural; Value : U64)
   is
      Bytes : Byte_Array (0 .. 7) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      for Index in Bytes'Range loop
         Bytes (Index) :=
           U8 (Interfaces.Shift_Right (Value, 8 * Index) and 16#FF#);
      end loop;
   end Put_64;

   ------------
   -- Put_32 --
   ------------

   procedure Put_32 (Base : System.Address; At_Offset : Natural; Value : U32)
   is
      Bytes : Byte_Array (0 .. 3) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      for Index in Bytes'Range loop
         Bytes (Index) :=
           U8 (Interfaces.Shift_Right (Value, 8 * Index) and 16#FF#);
      end loop;
   end Put_32;

   ------------
   -- Put_16 --
   ------------

   procedure Put_16 (Base : System.Address; At_Offset : Natural; Value : U16)
   is
      Bytes : Byte_Array (0 .. 1) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      for Index in Bytes'Range loop
         Bytes (Index) :=
           U8 (Interfaces.Shift_Right (Value, 8 * Index) and 16#FF#);
      end loop;
   end Put_16;

   ------------
   -- Get_16 --
   ------------

   function Get_16 (Base : System.Address; At_Offset : Natural) return U16 is
      Bytes : Byte_Array (0 .. 1) with Import,
        Address => Base + SSE.Storage_Offset (At_Offset);
   begin
      return U16 (Bytes (0)) or Interfaces.Shift_Left (U16 (Bytes (1)), 8);
   end Get_16;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready (BAR : Regions.Window) return Boolean is
     ((Reg.Read_Acquire_32 (BAR, Status_Register) and Status_Ready) /= 0);

   -------------
   -- Disable --
   -------------

   procedure Disable (BAR : Regions.Window; Attempts : Positive := 20_000) is
      Polls : Natural := 0;
   begin
      Reg.Write_32
        (BAR, Configuration_Register,
         Reg.Read_32 (BAR, Configuration_Register)
         and not Configuration_Enable);

      while Is_Ready (BAR) loop
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the controller was still ready after being disabled and"
              & Natural'Image (Attempts) & " polls. Its status register"
              & " reads" & U32'Image (Reg.Read_32 (BAR, Status_Register))
              & ".";
         end if;
      end loop;
   end Disable;

   ------------
   -- Enable --
   ------------

   procedure Enable
     (BAR        : Regions.Window;
      Submission : Queue_Location;
      Completion : Queue_Location;
      Attempts   : Positive := 20_000)
   is
      --  Both counts are held one less than the real number, as the
      --  specification defines them.
      Attributes : constant U32 :=
        U32 (Submission.Entries - 1)
        or Interfaces.Shift_Left (U32 (Completion.Entries - 1), 16);

      --  Enable, with the smallest page size, the NVM command set, and the
      --  entry sizes the specification fixes for those queues: sixty-four
      --  bytes of submission entry and sixteen of completion.
      Configuration : constant U32 :=
        Configuration_Enable
        or Interfaces.Shift_Left (6, 16)
        or Interfaces.Shift_Left (4, 20);

      Polls : Natural := 0;
   begin
      Reg.Write_32 (BAR, Admin_Queue_Attributes_Register, Attributes);
      Reg.Write_64 (BAR, Admin_Submission_Queue_Register, Submission.Device);
      Reg.Write_64 (BAR, Admin_Completion_Queue_Register, Completion.Device);

      --  A release store: the queue addresses must be visible to the
      --  controller before it is told it may start using them.
      Reg.Write_Release_32 (BAR, Configuration_Register, Configuration);

      loop
         exit when Is_Ready (BAR);

         if (Reg.Read_32 (BAR, Status_Register) and Status_Fatal) /= 0 then
            raise Device_Misbehaved with
              "the controller reported a fatal error rather than becoming"
              & " ready. It had been given an admin submission queue at"
              & U64'Image (Submission.Device) & " and a completion queue at"
              & U64'Image (Completion.Device) & ".";
         end if;

         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the controller did not become ready after"
              & Natural'Image (Attempts) & " polls. It reads its admin"
              & " queues by DMA as it starts, so an address it cannot reach"
              & " looks exactly like this: no error, no readiness. Check"
              & " that bus mastering is enabled and that"
              & U64'Image (Submission.Device) & " and"
              & U64'Image (Completion.Device) & " are mapped.";
         end if;
      end loop;
   end Enable;

   -----------------------------
   -- Write_Identify_Command --
   -----------------------------

   procedure Write_Identify_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Result_Address : U64)
   is
      Base  : constant System.Address := Submission.Host;
      Entry_At : constant Natural := Slot * Submission_Entry_Bytes;
      Blank : Byte_Array (0 .. Submission_Entry_Bytes - 1) with Import,
        Address => Base + SSE.Storage_Offset (Entry_At);
   begin
      Blank := (others => 0);

      --  Opcode six is Identify, and the tenth command word selects which
      --  structure: one is the controller itself.
      Put_32 (Base, Entry_At + 0, 16#06#);
      Put_16 (Base, Entry_At + 2, Identifier);
      Put_32 (Base, Entry_At + 4, 0);
      Put_64 (Base, Entry_At + 24, Result_Address);
      Put_32 (Base, Entry_At + 40, 1);
   end Write_Identify_Command;

   ---------------------------------
   -- Ring_Submission_Doorbell --
   ---------------------------------

   procedure Ring_Submission_Doorbell
     (BAR    : Regions.Window;
      Stride : Positive;
      Queue  : Natural;
      Tail   : Natural)
   is
   begin
      Reg.Write_Release_32
        (BAR,
         DMA.Byte_Count (Doorbell_Base + 2 * Queue * Stride),
         U32 (Tail));
   end Ring_Submission_Doorbell;

   ---------------------------------
   -- Ring_Completion_Doorbell --
   ---------------------------------

   procedure Ring_Completion_Doorbell
     (BAR    : Regions.Window;
      Stride : Positive;
      Queue  : Natural;
      Head   : Natural)
   is
   begin
      Reg.Write_Release_32
        (BAR,
         DMA.Byte_Count (Doorbell_Base + (2 * Queue + 1) * Stride),
         U32 (Head));
   end Ring_Completion_Doorbell;

   ----------------------
   -- Read_Completion --
   ----------------------

   function Read_Completion
     (Queue : Queue_Location; Slot : Natural) return Completion
   is
      Entry_At : constant Natural := Slot * Completion_Entry_Bytes;
      Raw      : constant U16 := Get_16 (Queue.Host, Entry_At + 14);
   begin
      return
        (Identifier => Get_16 (Queue.Host, Entry_At + 12),
         Status     => Interfaces.Shift_Right (Raw, 1),
         Phase      => (Raw and 1) /= 0);
   end Read_Completion;

   -----------------------
   -- Await_Completion --
   -----------------------

   function Await_Completion
     (Queue          : Queue_Location;
      Slot           : Natural;
      Expected_Phase : Boolean;
      Attempts       : Positive := 20_000) return Completion
   is
      Polls : Natural := 0;
      Seen  : Completion;
   begin
      loop
         Seen := Read_Completion (Queue, Slot);
         exit when Seen.Phase = Expected_Phase;

         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "no completion appeared in slot" & Natural'Image (Slot)
              & " after" & Natural'Image (Attempts) & " polls. The"
              & " controller writes completions by DMA, so an unreachable"
              & " completion queue produces exactly this silence.";
         end if;
      end loop;
      return Seen;
   end Await_Completion;

   -------------------------
   -- Identified_Vendor --
   -------------------------

   function Identified_Vendor (Data : System.Address) return U16 is
     (Get_16 (Data, 0));

   --  Both strings are fixed-width and padded with spaces rather than
   --  terminated, so the end has to be found by trimming.
   function Trimmed
     (Data : System.Address; At_Offset : Natural; Width : Positive)
      return String;

   -------------
   -- Trimmed --
   -------------

   function Trimmed
     (Data : System.Address; At_Offset : Natural; Width : Positive)
      return String
   is
      Bytes : Byte_Array (0 .. Width - 1) with Import,
        Address => Data + SSE.Storage_Offset (At_Offset);
      Text  : String (1 .. Width);
      Last  : Natural := 0;
   begin
      for Index in Bytes'Range loop
         Text (Index + 1) := Character'Val (Natural (Bytes (Index)));
      end loop;
      Last := Text'Last;
      while Last >= Text'First
        and then (Text (Last) = ' ' or else Text (Last) = ASCII.NUL)
      loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Trimmed;

   -------------------------
   -- Identified_Serial --
   -------------------------

   function Identified_Serial (Data : System.Address) return String is
     (Trimmed (Data, 4, 20));

   ------------------------
   -- Identified_Model --
   ------------------------

   function Identified_Model (Data : System.Address) return String is
     (Trimmed (Data, 24, 40));

end Flyology_VFIO_QEMU.NVMe;
