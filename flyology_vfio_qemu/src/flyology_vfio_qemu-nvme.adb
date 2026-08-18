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

   --------------------
   -- Write_Command --
   --------------------

   procedure Write_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Opcode     : U8;
      Identifier : U16;
      Namespace  : U32 := 0;
      DPTR1      : U64 := 0;
      DPTR2      : U64 := 0;
      CDW10      : U32 := 0;
      CDW11      : U32 := 0;
      CDW12      : U32 := 0)
   is
      Base     : constant System.Address := Submission.Host;
      Entry_At : constant Natural := Slot * Submission_Entry_Bytes;
      Blank    : Byte_Array (0 .. Submission_Entry_Bytes - 1) with Import,
        Address => Base + SSE.Storage_Offset (Entry_At);
   begin
      --  Cleared first. Every field this command does not use must be zero,
      --  and a slot being reused still holds the last command that went
      --  through it.
      Blank := (others => 0);

      Put_32 (Base, Entry_At + 0, U32 (Opcode));
      Put_16 (Base, Entry_At + 2, Identifier);
      Put_32 (Base, Entry_At + 4, Namespace);
      Put_64 (Base, Entry_At + 24, DPTR1);
      Put_64 (Base, Entry_At + 32, DPTR2);
      Put_32 (Base, Entry_At + 40, CDW10);
      Put_32 (Base, Entry_At + 44, CDW11);
      Put_32 (Base, Entry_At + 48, CDW12);
   end Write_Command;

   -----------------------------
   -- Write_Identify_Command --
   -----------------------------

   procedure Write_Identify_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Result_Address : U64)
   is
   begin
      Write_Command
        (Submission, Slot, Opcode_Identify, Identifier,
         DPTR1 => Result_Address, CDW10 => Identify_Controller);
   end Write_Identify_Command;

   ----------------------------------------
   -- Write_Identify_Namespace_Command --
   ----------------------------------------

   procedure Write_Identify_Namespace_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Namespace      : U32;
      Result_Address : U64)
   is
   begin
      Write_Command
        (Submission, Slot, Opcode_Identify, Identifier,
         Namespace => Namespace, DPTR1 => Result_Address,
         CDW10 => Identify_Namespace);
   end Write_Identify_Namespace_Command;

   -------------------------------------------
   -- Write_Create_Completion_Queue_Command --
   -------------------------------------------

   procedure Write_Create_Completion_Queue_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Queue_Number : Positive;
      Entries      : Positive;
      Address      : U64)
   is
   begin
      --  Bit zero of the eleventh word says the queue is one contiguous
      --  run of memory rather than a list of pages. It is, because it was
      --  carved out of a single mapped region.
      Write_Command
        (Submission, Slot, Opcode_Create_Completion_Queue, Identifier,
         DPTR1 => Address,
         CDW10 => U32 (Queue_Number)
                  or Interfaces.Shift_Left (U32 (Entries - 1), 16),
         CDW11 => 1);
   end Write_Create_Completion_Queue_Command;

   -------------------------------------------
   -- Write_Create_Submission_Queue_Command --
   -------------------------------------------

   procedure Write_Create_Submission_Queue_Command
     (Submission       : Queue_Location;
      Slot             : Natural;
      Identifier       : U16;
      Queue_Number     : Positive;
      Completion_Number : Positive;
      Entries          : Positive;
      Address          : U64)
   is
   begin
      Write_Command
        (Submission, Slot, Opcode_Create_Submission_Queue, Identifier,
         DPTR1 => Address,
         CDW10 => U32 (Queue_Number)
                  or Interfaces.Shift_Left (U32 (Entries - 1), 16),
         CDW11 => 1
                  or Interfaces.Shift_Left (U32 (Completion_Number), 16));
   end Write_Create_Submission_Queue_Command;

   -------------------------------
   -- Write_Delete_Queue_Command --
   -------------------------------

   procedure Write_Delete_Queue_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Opcode       : U8;
      Queue_Number : Positive)
   is
   begin
      Write_Command
        (Submission, Slot, Opcode, Identifier,
         CDW10 => U32 (Queue_Number));
   end Write_Delete_Queue_Command;

   ---------------------------
   -- Write_Block_Command --
   ---------------------------

   procedure Write_Block_Command
     (Submission  : Queue_Location;
      Slot        : Natural;
      Identifier  : U16;
      Opcode      : U8;
      Namespace   : U32;
      First_Block : U64;
      Blocks      : Positive;
      Address     : U64)
   is
   begin
      --  The block count is held one less than the real number, which is
      --  the single most reliable way to write a driver that transfers one
      --  block too few or one too many.
      Write_Command
        (Submission, Slot, Opcode, Identifier,
         Namespace => Namespace,
         DPTR1 => Address,
         CDW10 => U32 (First_Block and 16#FFFF_FFFF#),
         CDW11 => U32 (Interfaces.Shift_Right (First_Block, 32)),
         CDW12 => U32 (Blocks - 1));
   end Write_Block_Command;

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

   -----------------------------------
   -- Identified_Namespace_Count --
   -----------------------------------

   function Identified_Namespace_Count (Data : System.Address) return U32 is
      Bytes : Byte_Array (0 .. 3) with Import,
        Address => Data + SSE.Storage_Offset (516);
   begin
      return U32 (Bytes (0))
        or Interfaces.Shift_Left (U32 (Bytes (1)), 8)
        or Interfaces.Shift_Left (U32 (Bytes (2)), 16)
        or Interfaces.Shift_Left (U32 (Bytes (3)), 24);
   end Identified_Namespace_Count;

   ------------------------
   -- Namespace_Blocks --
   ------------------------

   function Namespace_Blocks (Data : System.Address) return U64 is
      Bytes : Byte_Array (0 .. 7) with Import, Address => Data;
      Total : U64 := 0;
   begin
      for Index in reverse Bytes'Range loop
         Total := Interfaces.Shift_Left (Total, 8) or U64 (Bytes (Index));
      end loop;
      return Total;
   end Namespace_Blocks;

   -----------------------------
   -- Namespace_Block_Bytes --
   -----------------------------

   function Namespace_Block_Bytes (Data : System.Address) return Positive is
      --  Byte 26 says which of the sixteen possible formats is in use, and
      --  each format is a four-byte entry starting at byte 128 whose third
      --  byte holds the base-two logarithm of the block size. Assuming 512
      --  bytes is the classic way to write a driver that works on every
      --  disk the author owned.
      Selected : Byte_Array (0 .. 0) with Import,
        Address => Data + SSE.Storage_Offset (26);
      Format   : constant Natural := Natural (Selected (0) and 16#0F#);
      Entry_At : constant Natural := 128 + 4 * Format;
      Exponent : Byte_Array (0 .. 0) with Import,
        Address => Data + SSE.Storage_Offset (Entry_At + 2);
      Power    : constant Natural := Natural (Exponent (0));
   begin
      if Power < 9 or else Power > 20 then
         raise Device_Misbehaved with
           "the namespace reports a logical block size of two to the"
           & Natural'Image (Power) & ", which is outside anything the"
           & " specification allows";
      end if;
      return 2 ** Power;
   end Namespace_Block_Bytes;

end Flyology_VFIO_QEMU.NVMe;
