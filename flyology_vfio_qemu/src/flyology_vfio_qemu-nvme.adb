with Flyology_VFIO.Registers;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_VFIO_QEMU.NVMe is

   package Reg renames Flyology_VFIO.Registers;
   package DMA renames Flyology_DMA;
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
     (BAR              : Regions.Window;
      Submission       : Queue_Location;
      Completion       : Queue_Location;
      Attempts         : Positive := 20_000;
      All_Command_Sets : Boolean := True)
   is
      Capabilities : constant U64 :=
        Reg.Read_64 (BAR, Capabilities_Register);

      --  Six selects every I/O command set the controller supports; zero
      --  selects the basic one alone. Asking for six on a controller that
      --  does not offer it is refused, so the choice follows what the
      --  capabilities register reports rather than what was asked for.
      Command_Sets : constant U32 :=
        (if All_Command_Sets
           and then Supports_Multiple_Command_Sets (Capabilities)
         then Interfaces.Shift_Left (6, 4)
         else 0);
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
        or Command_Sets
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

   --  Both public forms funnel through this. The opcode arrives already
   --  narrowed to a byte, because by that point the type system has done
   --  its work and which queue it belongs to is settled.
   procedure Write_Raw_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Opcode     : U8;
      Identifier : U16;
      Namespace  : Namespace_Identifier;
      DPTR1      : U64;
      DPTR2      : U64;
      CDW10      : U32;
      CDW11      : U32;
      CDW12      : U32;
      CDW13      : U32)
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
      Put_32 (Base, Entry_At + 4, U32 (Namespace));
      Put_64 (Base, Entry_At + 24, DPTR1);
      Put_64 (Base, Entry_At + 32, DPTR2);
      Put_32 (Base, Entry_At + 40, CDW10);
      Put_32 (Base, Entry_At + 44, CDW11);
      Put_32 (Base, Entry_At + 48, CDW12);
      Put_32 (Base, Entry_At + 52, CDW13);
   end Write_Raw_Command;

   ---------------------------
   -- Write_Admin_Command --
   ---------------------------

   procedure Write_Admin_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Opcode     : Admin_Opcode;
      Identifier : U16;
      Namespace  : Namespace_Identifier := No_Namespace;
      DPTR1      : U64 := 0;
      DPTR2      : U64 := 0;
      CDW10      : U32 := 0;
      CDW11      : U32 := 0;
      CDW12      : U32 := 0;
      CDW13      : U32 := 0)
   is
   begin
      Write_Raw_Command
        (Submission, Slot, U8 (Opcode), Identifier, Namespace,
         DPTR1, DPTR2, CDW10, CDW11, CDW12, CDW13);
   end Write_Admin_Command;

   ------------------------
   -- Write_IO_Command --
   ------------------------

   procedure Write_IO_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Opcode     : IO_Opcode;
      Identifier : U16;
      Namespace  : Namespace_Identifier;
      DPTR1      : U64 := 0;
      DPTR2      : U64 := 0;
      CDW10      : U32 := 0;
      CDW11      : U32 := 0;
      CDW12      : U32 := 0;
      CDW13      : U32 := 0)
   is
   begin
      Write_Raw_Command
        (Submission, Slot, U8 (Opcode), Identifier, Namespace,
         DPTR1, DPTR2, CDW10, CDW11, CDW12, CDW13);
   end Write_IO_Command;

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
      Write_Admin_Command
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
      Namespace      : Namespace_Identifier;
      Result_Address : U64)
   is
   begin
      Write_Admin_Command
        (Submission, Slot, Opcode_Identify, Identifier,
         Namespace => Namespace, DPTR1 => Result_Address,
         CDW10 => Identify_Namespace);
   end Write_Identify_Namespace_Command;

   -------------------------------------------
   -- Write_Create_Completion_Queue_Command --
   -------------------------------------------

   procedure Write_Create_Completion_Queue_Command
     (Submission       : Queue_Location;
      Slot             : Natural;
      Identifier       : U16;
      Queue_Number     : Queue_Identifier;
      Entries          : Positive;
      Address          : U64;
      Interrupt_Vector : Interrupt_Selection := No_Interrupt)
   is
      --  Bit zero says the queue is one contiguous run of memory rather
      --  than a list of pages. It is, because it was carved out of a single
      --  mapped region. Bit one asks for interrupts, and the vector goes in
      --  the top half of the same word.
      Contiguous : constant U32 := 1;
      Enabled    : constant U32 :=
        (if Interrupt_Vector = No_Interrupt then 0 else 2);
      Vector     : constant U32 :=
        (if Interrupt_Vector = No_Interrupt then 0
         else Interfaces.Shift_Left (U32 (Interrupt_Vector), 16));
   begin
      Write_Admin_Command
        (Submission, Slot, Opcode_Create_Completion_Queue, Identifier,
         DPTR1 => Address,
         CDW10 => U32 (Queue_Number)
                  or Interfaces.Shift_Left (U32 (Entries - 1), 16),
         CDW11 => Contiguous or Enabled or Vector);
   end Write_Create_Completion_Queue_Command;

   -------------------------------------------
   -- Write_Create_Submission_Queue_Command --
   -------------------------------------------

   procedure Write_Create_Submission_Queue_Command
     (Submission       : Queue_Location;
      Slot             : Natural;
      Identifier       : U16;
      Queue_Number      : Queue_Identifier;
      Completion_Number : Queue_Identifier;
      Entries           : Positive;
      Address           : U64)
   is
   begin
      Write_Admin_Command
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
      Opcode       : Admin_Opcode;
      Queue_Number : Queue_Identifier)
   is
   begin
      Write_Admin_Command
        (Submission, Slot, Opcode, Identifier,
         CDW10 => U32 (Queue_Number));
   end Write_Delete_Queue_Command;

   ---------------------------
   -- Write_Block_Command --
   ---------------------------

   procedure Write_Block_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Opcode       : IO_Opcode;
      Namespace    : Namespace_Identifier;
      First_Block  : U64;
      Blocks       : Positive;
      Address      : U64;
      Continuation : U64 := 0)
   is
   begin
      --  The block count is held one less than the real number, which is
      --  the single most reliable way to write a driver that transfers one
      --  block too few or one too many.
      Write_IO_Command
        (Submission, Slot, Opcode, Identifier,
         Namespace => Namespace,
         DPTR1 => Address,
         DPTR2 => Continuation,
         CDW10 => U32 (First_Block and 16#FFFF_FFFF#),
         CDW11 => U32 (Interfaces.Shift_Right (First_Block, 32)),
         CDW12 => U32 (Blocks - 1));
   end Write_Block_Command;

   ------------------------------
   -- Write_Feature_Command --
   ------------------------------

   procedure Write_Feature_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Identifier : U16;
      Opcode     : Admin_Opcode;
      Feature    : Feature_Identifier;
      Value      : U32 := 0;
      Namespace  : Namespace_Identifier := No_Namespace;
      Selection  : Feature_Selection := Current;
      Save       : Boolean := False)
   is
      --  The selection occupies bits ten and eleven of the tenth word on a
      --  Get; the save bit is the top bit of the same word on a Set. They
      --  share a word and mean nothing to the other command, which is why
      --  both are set unconditionally and only one is ever read.
      Selected : constant U32 :=
        Interfaces.Shift_Left
          (U32 (Feature_Selection'Pos (Selection)), 8);
      Persisted : constant U32 := (if Save then 2 ** 31 else 0);
   begin
      Write_Admin_Command
        (Submission, Slot, Opcode, Identifier,
         Namespace => Namespace,
         CDW10 => U32 (Feature) or Selected or Persisted,
         CDW11 => Value);
   end Write_Feature_Command;

   --------------------------
   -- Shutdown_Progress --
   --------------------------

   function Shutdown_Progress (BAR : Regions.Window) return Natural is
     (Shutdown_State (Reg.Read_Acquire_32 (BAR, Status_Register)));

   -----------------
   -- Shut_Down --
   -----------------

   procedure Shut_Down (BAR : Regions.Window; Attempts : Positive := 20_000)
   is
      Polls : Natural := 0;
   begin
      Reg.Write_Release_32
        (BAR, Configuration_Register,
         Reg.Read_32 (BAR, Configuration_Register)
         or Configuration_Shutdown_Normal);

      --  Two means complete. One means the controller is still committing,
      --  which is exactly the state a driver must not mistake for done.
      while Shutdown_Progress (BAR) /= 2 loop
         Polls := Polls + 1;
         Wait_Microseconds (100);
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the controller had not finished shutting down after"
              & Natural'Image (Attempts) & " polls; its status register"
              & " reports shutdown state"
              & Natural'Image (Shutdown_Progress (BAR));
         end if;
      end loop;
   end Shut_Down;

   -------------------------------
   -- Write_Log_Page_Command --
   -------------------------------

   procedure Write_Log_Page_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Log            : Log_Identifier;
      Bytes          : Positive;
      Result_Address : U64;
      Namespace      : Namespace_Identifier := All_Namespaces)
   is
      --  The length field counts thirty-two bit words and is held one less
      --  than the real number.
      Words : constant U32 := U32 (Bytes / 4) - 1;
   begin
      Write_Admin_Command
        (Submission, Slot, Opcode_Get_Log_Page, Identifier,
         Namespace => Namespace,
         DPTR1 => Result_Address,
         CDW10 => U32 (Log)
                  or Interfaces.Shift_Left (Words and 16#FFFF#, 16),
         CDW11 => Interfaces.Shift_Right (Words, 16));
   end Write_Log_Page_Command;

   -----------------------------
   -- Write_Simple_Command --
   -----------------------------

   procedure Write_Simple_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Identifier : U16;
      Opcode     : IO_Opcode;
      Namespace  : Namespace_Identifier)
   is
   begin
      Write_IO_Command (Submission, Slot, Opcode, Identifier,
                        Namespace => Namespace);
   end Write_Simple_Command;

   ----------------------------------
   -- Write_Block_Range_Command --
   ----------------------------------

   procedure Write_Block_Range_Command
     (Submission  : Queue_Location;
      Slot        : Natural;
      Identifier  : U16;
      Opcode      : IO_Opcode;
      Namespace   : Namespace_Identifier;
      First_Block : U64;
      Blocks      : Positive)
   is
   begin
      Write_IO_Command
        (Submission, Slot, Opcode, Identifier,
         Namespace => Namespace,
         CDW10 => U32 (First_Block and 16#FFFF_FFFF#),
         CDW11 => U32 (Interfaces.Shift_Right (First_Block, 32)),
         CDW12 => U32 (Blocks - 1));
   end Write_Block_Range_Command;

   ----------------------------
   -- Write_Abort_Command --
   ----------------------------

   procedure Write_Abort_Command
     (Submission        : Queue_Location;
      Slot              : Natural;
      Identifier        : U16;
      Target_Queue      : Queue_Identifier;
      Target_Identifier : U16)
   is
   begin
      Write_Admin_Command
        (Submission, Slot, Opcode_Abort, Identifier,
         CDW10 => U32 (Target_Queue)
                  or Interfaces.Shift_Left (U32 (Target_Identifier), 16));
   end Write_Abort_Command;

   ---------------------------------
   -- Write_Deallocate_Command --
   ---------------------------------

   procedure Write_Deallocate_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Namespace    : Namespace_Identifier;
      Ranges       : Positive;
      List_Address : U64)
   is
   begin
      --  Bit two of the eleventh word is what makes this a deallocation
      --  rather than a hint about access patterns. The range count is held
      --  one less than the real number, as everything else here is.
      Write_IO_Command
        (Submission, Slot, Opcode_Dataset_Management, Identifier,
         Namespace => Namespace,
         DPTR1 => List_Address,
         CDW10 => U32 (Ranges - 1),
         CDW11 => 4);
   end Write_Deallocate_Command;

   -------------------------------
   -- Write_Deallocate_Range --
   -------------------------------

   procedure Write_Deallocate_Range
     (List        : System.Address;
      Index       : Natural;
      First_Block : U64;
      Blocks      : Positive)
   is
      At_Offset : constant Natural := Index * 16;
      Blank : Byte_Array (0 .. 15) with Import,
        Address => List + SSE.Storage_Offset (At_Offset);
   begin
      Blank := (others => 0);
      Put_32 (List, At_Offset + 4, U32 (Blocks));
      Put_64 (List, At_Offset + 8, First_Block);
   end Write_Deallocate_Range;

   ---------------------------------
   -- Write_Zone_Report_Command --
   ---------------------------------

   procedure Write_Zone_Report_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Namespace      : Namespace_Identifier;
      First_Block    : U64;
      Bytes          : Positive;
      Result_Address : U64)
   is
      --  Counted in thirty-two bit words, one less than the real number,
      --  like every other length in this specification.
      Words : constant U32 := U32 (Bytes / 4) - 1;
   begin
      --  The thirteenth word selects which report and which zones: zero
      --  asks for zone descriptors, and zero again asks for all states
      --  rather than one.
      Write_IO_Command
        (Submission, Slot, Opcode_Zone_Receive, Identifier,
         Namespace => Namespace,
         DPTR1 => Result_Address,
         CDW10 => U32 (First_Block and 16#FFFF_FFFF#),
         CDW11 => U32 (Interfaces.Shift_Right (First_Block, 32)),
         CDW12 => Words);
   end Write_Zone_Report_Command;

   ---------------------------------
   -- Write_Zone_Action_Command --
   ---------------------------------

   procedure Write_Zone_Action_Command
     (Submission  : Queue_Location;
      Slot        : Natural;
      Identifier  : U16;
      Namespace   : Namespace_Identifier;
      First_Block : U64;
      Action      : Zone_Action;
      All_Zones   : Boolean := False)
   is
      --  The action numbers are the specification's, and start at one
      --  rather than zero, so the enumeration position will not serve.
      Code : constant U32 :=
        (case Action is
            when Close   => 16#01#,
            when Finish  => 16#02#,
            when Open    => 16#03#,
            when Reset   => 16#04#,
            when Offline => 16#05#);
      Sweep : constant U32 := (if All_Zones then 2 ** 8 else 0);
   begin
      Write_IO_Command
        (Submission, Slot, Opcode_Zone_Send, Identifier,
         Namespace => Namespace,
         CDW10 => U32 (First_Block and 16#FFFF_FFFF#),
         CDW11 => U32 (Interfaces.Shift_Right (First_Block, 32)),
         CDW13 => Code or Sweep);
   end Write_Zone_Action_Command;

   ---------------------------------
   -- Write_Zone_Append_Command --
   ---------------------------------

   procedure Write_Zone_Append_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Identifier : U16;
      Namespace  : Namespace_Identifier;
      Zone_Start : U64;
      Blocks     : Positive;
      Address    : U64)
   is
   begin
      --  The block named is the start of the zone, not where the data will
      --  go. Where it goes is the controller's decision and it reports it
      --  in the completion, which is the whole point of an append.
      Write_IO_Command
        (Submission, Slot, Opcode_Zone_Append, Identifier,
         Namespace => Namespace,
         DPTR1 => Address,
         CDW10 => U32 (Zone_Start and 16#FFFF_FFFF#),
         CDW11 => U32 (Interfaces.Shift_Right (Zone_Start, 32)),
         CDW12 => U32 (Blocks - 1));
   end Write_Zone_Append_Command;

   -----------------------------------------
   -- Write_Namespace_Attachment_Command --
   -----------------------------------------

   procedure Write_Namespace_Attachment_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Namespace    : Namespace_Identifier;
      Attach       : Boolean;
      List_Address : U64)
   is
   begin
      Write_Admin_Command
        (Submission, Slot, Opcode_Namespace_Attachment, Identifier,
         Namespace => Namespace,
         DPTR1 => List_Address,
         CDW10 => (if Attach then 0 else 1));
   end Write_Namespace_Attachment_Command;

   --------------------------------
   -- Write_Controller_List --
   --------------------------------

   procedure Write_Controller_List
     (List : System.Address; Controller : U16)
   is
      Blank : Byte_Array (0 .. 4095) with Import, Address => List;
   begin
      Blank := (others => 0);
      --  A count, then the identifiers. One entry here.
      Put_16 (List, 0, 1);
      Put_16 (List, 2, Controller);
   end Write_Controller_List;

   ------------------------
   -- Reported_Zones --
   ------------------------

   function Reported_Zones (Report : System.Address) return U64 is
      Bytes : Byte_Array (0 .. 7) with Import, Address => Report;
      Total : U64 := 0;
   begin
      for Index in reverse Bytes'Range loop
         Total := Interfaces.Shift_Left (Total, 8) or U64 (Bytes (Index));
      end loop;
      return Total;
   end Reported_Zones;

   ----------------------
   -- Reported_Zone --
   ----------------------

   function Reported_Zone
     (Report : System.Address; Index : Natural) return Zone_Description
   is
      At_Offset : constant Natural :=
        Zone_Report_Header_Bytes + Index * Zone_Descriptor_Bytes;

      function Field (Where : Natural) return U64;

      function Field (Where : Natural) return U64 is
         Bytes : Byte_Array (0 .. 7) with Import,
           Address => Report + SSE.Storage_Offset (At_Offset + Where);
         Total : U64 := 0;
      begin
         for Position in reverse Bytes'Range loop
            Total :=
              Interfaces.Shift_Left (Total, 8) or U64 (Bytes (Position));
         end loop;
         return Total;
      end Field;

      Status : Byte_Array (0 .. 0) with Import,
        Address => Report + SSE.Storage_Offset (At_Offset + 1);
      Coded  : constant Natural :=
        Natural (Interfaces.Shift_Right (Status (0), 4));
   begin
      return
        (Start         => Field (16),
         Capacity      => Field (8),
         Write_Pointer => Field (24),
         State         =>
           (case Coded is
               when 1 => Empty,
               when 2 => Implicitly_Open,
               when 3 => Explicitly_Open,
               when 4 => Closed,
               when 13 => Read_Only,
               when 14 => Full,
               when 15 => Offline,
               when others => Unknown));
   end Reported_Zone;

   ---------------------
   -- Appended_At --
   ---------------------

   function Appended_At
     (Queue : Queue_Location; Slot : Natural) return U64
   is
      Entry_At : constant Natural := Slot * Completion_Entry_Bytes;
      Bytes    : Byte_Array (0 .. 7) with Import,
        Address => Queue.Host + SSE.Storage_Offset (Entry_At);
      Total    : U64 := 0;
   begin
      --  The first two words of a completion carry the block the append
      --  landed on, which is the answer the command exists to give.
      for Index in reverse Bytes'Range loop
         Total := Interfaces.Shift_Left (Total, 8) or U64 (Bytes (Index));
      end loop;
      return Total;
   end Appended_At;

   ---------------------------
   -- Completion_Result --
   ---------------------------

   function Completion_Result
     (Queue : Queue_Location; Slot : Natural) return U32
   is
      Entry_At : constant Natural := Slot * Completion_Entry_Bytes;
      Bytes    : Byte_Array (0 .. 3) with Import,
        Address => Queue.Host + SSE.Storage_Offset (Entry_At);
   begin
      return U32 (Bytes (0))
        or Interfaces.Shift_Left (U32 (Bytes (1)), 8)
        or Interfaces.Shift_Left (U32 (Bytes (2)), 16)
        or Interfaces.Shift_Left (U32 (Bytes (3)), 24);
   end Completion_Result;

   ---------------------------------
   -- Ring_Submission_Doorbell --
   ---------------------------------

   procedure Ring_Submission_Doorbell
     (BAR    : Regions.Window;
      Stride : Positive;
      Queue  : Queue_Identifier;
      Tail   : Natural)
   is
   begin
      Reg.Write_Release_32
        (BAR,
         DMA.Byte_Count (Doorbell_Base + 2 * Natural (Queue) * Stride),
         U32 (Tail));
   end Ring_Submission_Doorbell;

   ---------------------------------
   -- Ring_Completion_Doorbell --
   ---------------------------------

   procedure Ring_Completion_Doorbell
     (BAR    : Regions.Window;
      Stride : Positive;
      Queue  : Queue_Identifier;
      Head   : Natural)
   is
   begin
      Reg.Write_Release_32
        (BAR,
         DMA.Byte_Count (Doorbell_Base + (2 * Natural (Queue) + 1) * Stride),
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
      --  The phase bit above is what says the rest of this entry — and the
      --  buffer the command filled — is there to be read. Volatile keeps
      --  the compiler from reordering those reads and says nothing to the
      --  processor, which on a weakly ordered machine may satisfy them
      --  from before the phase was written. Under emulation the two are
      --  never separable; on silicon they are.
      Reg.Load_Fence;
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

   -----------------------------------------
   -- Write_Directive_Receive_Command --
   -----------------------------------------

   procedure Write_Directive_Receive_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Namespace      : Namespace_Identifier;
      Result_Address : U64;
      Bytes          : Positive;
      Directive      : Directive_Kind := Directive_Identify;
      Operation      : Directive_Operation := Directive_Return_Parameters;
      Specific       : U16 := 0)
   is
      Words : constant U32 := U32 (Bytes / 4) - 1;
   begin
      --  The tenth word is a length in words, one less than the real
      --  number. The eleventh packs three unrelated things: which operation
      --  in its lowest byte, which directive in the next, and a
      --  directive-specific value in the high half that most directives
      --  ignore.
      Write_Admin_Command
        (Submission, Slot, Opcode_Directive_Receive, Identifier,
         Namespace => Namespace,
         DPTR1 => Result_Address,
         CDW10 => Words,
         CDW11 => U32 (Operation)
                  or Interfaces.Shift_Left (U32 (Directive), 8)
                  or Interfaces.Shift_Left (U32 (Specific), 16));
   end Write_Directive_Receive_Command;

   --------------------------------------
   -- Write_Directive_Send_Command --
   --------------------------------------

   procedure Write_Directive_Send_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Namespace      : Namespace_Identifier;
      Buffer_Address : U64 := 0;
      Bytes          : Natural := 0;
      Directive      : Directive_Kind := Directive_Identify;
      Operation      : Directive_Operation := Directive_Enable;
      Specific       : U16 := 0;
      Enable         : Enable_Directive := No_Directive_Change)
   is
      Words : constant U32 :=
        (if Bytes = 0 then 0 else U32 (Bytes / 4) - 1);
   begin
      --  The type to switch goes in bits fifteen to eight of the twelfth
      --  word and the switch itself in its lowest bit.
      Write_Admin_Command
        (Submission, Slot, Opcode_Directive_Send, Identifier,
         Namespace => Namespace,
         DPTR1 => Buffer_Address,
         CDW10 => Words,
         CDW11 => U32 (Operation)
                  or Interfaces.Shift_Left (U32 (Directive), 8)
                  or Interfaces.Shift_Left (U32 (Specific), 16),
         CDW12 =>
           (if not Enable.Meant then 0
            else Interfaces.Shift_Left (U32 (Enable.Kind), 8)
                 or (if Enable.Switched_On then 1 else 0)));
   end Write_Directive_Send_Command;

   -------------------------------
   -- Directive_Bitmap_Bit --
   -------------------------------

   --  Whether the bit for a directive is set in a bitmap starting here.
   function Directive_Bitmap_Bit
     (Data : System.Address; At_Offset : Natural; Directive : Directive_Kind)
      return Boolean
   is
      Byte_At : constant Natural :=
        At_Offset + Natural (Directive) / 8;
      Within  : constant Natural := Natural (Directive) mod 8;
      Cell    : Byte_Array (0 .. 0) with Import,
        Address => Data + SSE.Storage_Offset (Byte_At);
   begin
      return (Interfaces.Shift_Right (Cell (0), Within) and 1) = 1;
   end Directive_Bitmap_Bit;

   ------------------------------
   -- Directive_Supported --
   ------------------------------

   function Directive_Supported
     (Data : System.Address; Directive : Directive_Kind) return Boolean
   is (Directive_Bitmap_Bit (Data, 0, Directive));

   ----------------------------
   -- Directive_Enabled --
   ----------------------------

   --  The enabled bitmap follows the supported one, both a fixed thirty-two
   --  bytes wide however few directives are defined.
   function Directive_Enabled
     (Data : System.Address; Directive : Directive_Kind) return Boolean
   is (Directive_Bitmap_Bit (Data, 32, Directive));

   ---------------------------------
   -- Copy_Format_Supported --
   ---------------------------------

   function Copy_Format_Supported
     (Data : System.Address; Format : Copy_Format) return Boolean
   is
      --  OCFS, at byte 534 of the Identify Controller structure: a bitmap
      --  indexed by format number rather than a count.
      Field : constant U16 := Get_16 (Data, 534);
      Bit   : constant Natural := Copy_Format'Pos (Format);
   begin
      return (Interfaces.Shift_Right (Field, Bit) and 1) = 1;
   end Copy_Format_Supported;

   --------------------------------
   -- Maximum_Copy_Sources --
   --------------------------------

   function Maximum_Copy_Sources (Data : System.Address) return Positive is
      --  MSRC, at byte 80 of the Identify Namespace structure, and 0's
      --  based like everything else that counts here. A namespace with no
      --  limit reports zero, which is indistinguishable from a limit of
      --  one; the specification chose that and callers live with it.
      Cell : Byte_Array (0 .. 0) with Import,
        Address => Data + SSE.Storage_Offset (80);
   begin
      return Natural (Cell (0)) + 1;
   end Maximum_Copy_Sources;

   ----------------------------------
   -- Write_Copy_Source_Range --
   ----------------------------------

   procedure Write_Copy_Source_Range
     (List        : System.Address;
      Index       : Natural;
      First_Block : U64;
      Blocks      : Positive;
      Format      : Copy_Format := Format_32_Byte)
   is
      Stride    : constant Positive := Copy_Range_Bytes (Format);
      At_Offset : constant Natural := Index * Stride;
      Blank : Byte_Array (0 .. Stride - 1) with Import,
        Address => List + SSE.Storage_Offset (At_Offset);
   begin
      Blank := (others => 0);
      Put_64 (List, At_Offset + 8, First_Block);
      Put_16 (List, At_Offset + 16, U16 (Blocks - 1));
   end Write_Copy_Source_Range;

   ----------------------------
   -- Write_Copy_Command --
   ----------------------------

   procedure Write_Copy_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Namespace    : Namespace_Identifier;
      List_Address : U64;
      Sources      : Positive;
      First_Block  : U64;
      Format       : Copy_Format := Format_32_Byte)
   is
   begin
      --  The destination is where an ordinary write would put its address,
      --  in the tenth and eleventh words. The twelfth holds the number of
      --  ranges one less than the real number in its lowest byte, and which
      --  layout they use in the next nibble up.
      Write_IO_Command
        (Submission, Slot, Opcode_Copy, Identifier,
         Namespace => Namespace,
         DPTR1 => List_Address,
         CDW10 => U32 (First_Block and 16#FFFF_FFFF#),
         CDW11 => U32 (Interfaces.Shift_Right (First_Block, 32)),
         CDW12 => U32 (Sources - 1)
                  or Interfaces.Shift_Left
                       (U32 (Copy_Format'Pos (Format)), 8));
   end Write_Copy_Command;

   ------------------------------
   -- Describe_Transfer --
   ------------------------------

   function Describe_Transfer
     (Buffer      : U64;
      Bytes       : Positive;
      Page_Bytes  : Positive;
      List_Host   : System.Address;
      List_Device : U64) return Data_Pointers
   is
      Span  : constant U64 := U64 (Page_Bytes);
      Pages : constant Natural :=
        Natural ((U64 (Bytes) + Span - 1) / Span);
   begin
      if (Buffer mod Span) /= 0 then
         raise Device_Misused with
           "a transfer buffer must start on a page boundary";
      end if;

      if Pages <= 1 then
         --  Everything is inside the first page, and the second pointer
         --  means nothing. Leaving a stale address there is harmless and
         --  leaving a wrong one is not, so it is zero.
         return (First => Buffer, Second => 0);
      elsif Pages = 2 then
         return (First => Buffer, Second => Buffer + Span);
      end if;

      if Pages - 1 > Page_List_Capacity (Page_Bytes) then
         raise Device_Misused with
           "a transfer of" & Positive'Image (Bytes)
           & " bytes needs a chained page list, which this does not build";
      end if;

      for Index in 0 .. Pages - 2 loop
         --  The list names every page after the first. The first stays in
         --  the first pointer, so entry zero is the second page and an
         --  off-by-one here transfers the whole buffer shifted by a page.
         Put_64 (List_Host, Index * 8, Buffer + Span * U64 (Index + 1));
      end loop;

      return (First => Buffer, Second => List_Device);
   end Describe_Transfer;

   -----------------------------------
   -- Maximum_Transfer_Bytes --
   -----------------------------------

   function Maximum_Transfer_Bytes
     (Data : System.Address; Capabilities : U64) return Natural
   is
      Cell : Byte_Array (0 .. 0) with Import,
        Address => Data + SSE.Storage_Offset (77);
      Shift : constant Natural := Natural (Cell (0));
   begin
      if Shift = 0 then
         return 0;
      end if;
      --  Guard the shift rather than the result: a controller claiming a
      --  transfer of two to the two hundredth bytes is not one to take at
      --  its word, and computing it would overflow before it could be
      --  disbelieved.
      if Shift > 20 then
         raise Device_Misbehaved with
           "the controller claims a maximum transfer of two to the"
           & Natural'Image (Shift) & " pages";
      end if;
      return Minimum_Page_Size (Capabilities) * (2 ** Shift);
   end Maximum_Transfer_Bytes;

end Flyology_VFIO_QEMU.NVMe;
