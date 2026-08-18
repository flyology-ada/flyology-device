with Flyology_VFIO.Registers;
with System.Storage_Elements;

package body Flyology_VFIO_QEMU.NVMe.Blocks is

   package Reg renames Flyology_VFIO.Registers;
   package SSE renames System.Storage_Elements;

   use type System.Address;
   use type SSE.Storage_Offset;

   --  Where each structure sits in the scratch area. A page each, in the
   --  order they are used, with the transfer buffer taking whatever is
   --  left. Overlapping two of these is the sort of mistake that produces a
   --  controller which works until it is busy.
   Admin_Sub_At  : constant := 0;
   Admin_Comp_At : constant := 4096;
   IO_Sub_At     : constant := 8192;
   IO_Comp_At    : constant := 12288;
   Identify_At   : constant := 16384;
   List_At       : constant := 20480;
   Buffer_At     : constant := 24576;

   function Run_Admin
     (Self : in out Volume; BAR : Regions.Window) return Completion;
   function Run_IO
     (Self : in out Volume; BAR : Regions.Window) return Completion;
   procedure Demand
     (Self : in out Volume; Answer : Completion; Doing : String);
   function Trimmed (Text : String) return String;
   function Padded (Text : String; Width : Positive) return String;

   -------------------
   -- Run_Admin --
   -------------------

   function Run_Admin
     (Self : in out Volume; BAR : Regions.Window) return Completion
   is
      Answer : Completion;
   begin
      Ring_Submission_Doorbell
        (BAR, Self.Stride, Admin_Queue,
         (Self.Admin_Slot + 1) mod Queue_Entries);
      Answer := Await_Completion (Self.Admin_Comp, Self.Admin_Slot, True);
      Ring_Completion_Doorbell
        (BAR, Self.Stride, Admin_Queue,
         (Self.Admin_Slot + 1) mod Queue_Entries);
      Self.Admin_Slot := Self.Admin_Slot + 1;
      Self.Next_ID := Self.Next_ID + 1;
      Self.Status := Answer.Status;
      return Answer;
   end Run_Admin;

   ----------------
   -- Run_IO --
   ----------------

   function Run_IO
     (Self : in out Volume; BAR : Regions.Window) return Completion
   is
      Answer : Completion;
   begin
      Ring_Submission_Doorbell
        (BAR, Self.Stride, IO_Queue, (Self.IO_Slot + 1) mod Queue_Entries);
      Answer := Await_Completion (Self.IO_Comp, Self.IO_Slot, True);
      Ring_Completion_Doorbell
        (BAR, Self.Stride, IO_Queue, (Self.IO_Slot + 1) mod Queue_Entries);
      Self.IO_Slot := Self.IO_Slot + 1;
      Self.Next_ID := Self.Next_ID + 1;
      Self.Status := Answer.Status;
      return Answer;
   end Run_IO;

   ----------------
   -- Demand --
   ----------------

   --  A block device that carried on after a refused command would be
   --  worse than one that stopped: the caller's next read would return
   --  whatever was in the buffer and look like data.
   procedure Demand
     (Self : in out Volume; Answer : Completion; Doing : String)
   is
   begin
      if Answer.Status /= 0 then
         Self.Status := Answer.Status;
         raise Device_Misbehaved with
           Doing & " was refused with status 0x" & Hex_16 (Answer.Status);
      end if;
   end Demand;

   -----------------
   -- Trimmed --
   -----------------

   function Trimmed (Text : String) return String is
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then Text (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Trimmed;

   ----------------
   -- Padded --
   ----------------

   --  The controller reports these already trimmed, and a Volume keeps them
   --  in fixed room so that it needs no heap. A name longer than the field
   --  is cut rather than raising: a model number is not worth failing a
   --  bring-up over.
   function Padded (Text : String; Width : Positive) return String is
      Result : String (1 .. Width) := [others => ' '];
      Taken  : constant Natural := Natural'Min (Text'Length, Width);
   begin
      Result (1 .. Taken) := Text (Text'First .. Text'First + Taken - 1);
      return Result;
   end Padded;

   --------------
   -- Open --
   --------------

   procedure Open
     (Self       : in out Volume;
      BAR        : Regions.Window;
      Scratch    : System.Address;
      Scratch_At : U64;
      Bytes      : Positive;
      Namespace  : Namespace_Identifier := 1)
   is
      Capabilities : constant U64 :=
        Reg.Read_64 (BAR, Capabilities_Register);

      function At_Host (Offset : Natural) return System.Address
      is (Scratch + SSE.Storage_Offset (Offset));

      function At_Device (Offset : Natural) return U64
      is (Scratch_At + U64 (Offset));
   begin
      Self.Opened := False;
      Self.Namespace := Namespace;
      Self.Stride := Doorbell_Stride (Capabilities);
      Self.Page_Bytes := Minimum_Page_Size (Capabilities);
      Self.Admin_Slot := 0;
      Self.IO_Slot := 0;
      Self.Next_ID := 1;
      Self.Status := 0;

      Self.Admin_Sub :=
        (Kind => Admin, Host => At_Host (Admin_Sub_At),
         Device => At_Device (Admin_Sub_At), Entries => Queue_Entries);
      Self.Admin_Comp :=
        (Kind => Admin, Host => At_Host (Admin_Comp_At),
         Device => At_Device (Admin_Comp_At), Entries => Queue_Entries);
      Self.IO_Sub :=
        (Kind => Namespace_IO, Host => At_Host (IO_Sub_At),
         Device => At_Device (IO_Sub_At), Entries => Queue_Entries);
      Self.IO_Comp :=
        (Kind => Namespace_IO, Host => At_Host (IO_Comp_At),
         Device => At_Device (IO_Comp_At), Entries => Queue_Entries);

      Self.List_Host := At_Host (List_At);
      Self.List_At := At_Device (List_At);
      Self.Buffer_Host := At_Host (Buffer_At);
      Self.Buffer_At := At_Device (Buffer_At);
      Self.Buffer_Bytes := Bytes - Buffer_At;

      declare
         Blank : array (1 .. Buffer_At) of U8
           with Import, Volatile, Address => Scratch;
      begin
         --  Only the structures, not the transfer buffer: a caller may
         --  have put something there already and clearing it would be a
         --  surprise rather than hygiene.
         Blank := [others => 0];
      end;

      Disable (BAR);
      Enable (BAR, Self.Admin_Sub, Self.Admin_Comp);

      ------------------------------------------------------------------
      --  What the controller and the namespace say about themselves
      ------------------------------------------------------------------

      Write_Identify_Command
        (Self.Admin_Sub, Self.Admin_Slot, Self.Next_ID,
         At_Device (Identify_At));
      Demand (Self, Run_Admin (Self, BAR), "identifying the controller");

      Self.Serial_Text := Padded (Identified_Serial (At_Host (Identify_At)), 20);
      Self.Model_Text := Padded (Identified_Model (At_Host (Identify_At)), 40);

      declare
         Ceiling : constant Natural :=
           Maximum_Transfer_Bytes (At_Host (Identify_At), Capabilities);
         Room : constant Positive :=
           (Self.Buffer_Bytes / Self.Page_Bytes) * Self.Page_Bytes;
      begin
         --  A controller stating no limit at all reports zero, so the
         --  scratch area is the only bound left.
         Self.Largest :=
           (if Ceiling = 0 then Room else Positive'Min (Ceiling, Room));

         --  And a transfer needing more page-list entries than one page
         --  holds cannot be described, whatever the controller allows.
         Self.Largest :=
           Positive'Min
             (Self.Largest,
              Self.Page_Bytes * Page_List_Capacity (Self.Page_Bytes));
      end;

      Write_Identify_Namespace_Command
        (Self.Admin_Sub, Self.Admin_Slot, Self.Next_ID, Namespace,
         At_Device (Identify_At));
      Demand (Self, Run_Admin (Self, BAR), "identifying the namespace");

      Self.Block_Size := Namespace_Block_Bytes (At_Host (Identify_At));
      Self.Blocks := Namespace_Blocks (At_Host (Identify_At));

      if Self.Blocks = 0 then
         raise Device_Misbehaved with
           "the namespace reports no blocks at all, so there is nothing"
           & " here to read or write";
      end if;

      if Self.Largest < Self.Block_Size then
         raise Device_Misbehaved with
           "one block is" & Positive'Image (Self.Block_Size)
           & " bytes and the largest transfer possible here is"
           & Positive'Image (Self.Largest);
      end if;

      ------------------------------------------------------------------
      --  Somewhere to send the work
      ------------------------------------------------------------------

      Write_Create_Completion_Queue_Command
        (Self.Admin_Sub, Self.Admin_Slot, Self.Next_ID, IO_Queue,
         Queue_Entries, Self.IO_Comp.Device);
      Demand (Self, Run_Admin (Self, BAR), "creating a completion queue");

      Write_Create_Submission_Queue_Command
        (Self.Admin_Sub, Self.Admin_Slot, Self.Next_ID, IO_Queue, IO_Queue,
         Queue_Entries, Self.IO_Sub.Device);
      Demand (Self, Run_Admin (Self, BAR), "creating a submission queue");

      Self.Opened := True;
   end Open;

   ---------------
   -- Close --
   ---------------

   procedure Close (Self : in out Volume; BAR : Regions.Window) is
   begin
      if Self.Opened then
         Self.Opened := False;
         Shut_Down (BAR);
      end if;
   end Close;

   ----------------
   -- Serial --
   ----------------

   function Serial (Self : Volume) return String is (Trimmed (Self.Serial_Text));

   ---------------
   -- Model --
   ---------------

   function Model (Self : Volume) return String is (Trimmed (Self.Model_Text));

   ------------------
   -- Transfer --
   ------------------

   --  One direction of block movement, since read and write differ only in
   --  the opcode and which way the bytes are copied.
   procedure Transfer
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      Data        : in out Byte_Sequence;
      Writing     : Boolean)
   is
      Total : constant Natural := Data'Length;
   begin
      if Total = 0 then
         return;
      end if;

      if Total mod Self.Block_Size /= 0 then
         raise Device_Misbehaved with
           "a transfer of" & Natural'Image (Total)
           & " bytes is not a whole number of"
           & Positive'Image (Self.Block_Size) & "-byte blocks";
      end if;

      declare
         Wanted : constant U64 := U64 (Total / Self.Block_Size);
      begin
         if First_Block > Self.Blocks
           or else Wanted > Self.Blocks - First_Block
         then
            raise Device_Misbehaved with
              "blocks" & U64'Image (First_Block) & " to"
              & U64'Image (First_Block + Wanted - 1)
              & " run past the end of a namespace holding"
              & U64'Image (Self.Blocks);
         end if;
      end;

      declare
         Chunk_Bytes : constant Positive :=
           (Self.Largest / Self.Block_Size) * Self.Block_Size;
         Done  : Natural := 0;
         Block : U64 := First_Block;
      begin
         while Done < Total loop
            declare
               Now : constant Positive :=
                 Positive'Min (Chunk_Bytes, Total - Done);
               Blocks_Now : constant Positive := Now / Self.Block_Size;
               Staging : Byte_Sequence (0 .. Now - 1)
                 with Import, Volatile, Address => Self.Buffer_Host;
               Pointers : constant Data_Pointers :=
                 Describe_Transfer
                   (Self.Buffer_At, Now, Self.Page_Bytes,
                    Self.List_Host, Self.List_At);
            begin
               if Writing then
                  Staging := Data (Data'First + Done
                                   .. Data'First + Done + Now - 1);
               end if;

               Write_Block_Command
                 (Self.IO_Sub, Self.IO_Slot, Self.Next_ID,
                  (if Writing then Opcode_Write else Opcode_Read),
                  Self.Namespace, Block, Blocks_Now,
                  Pointers.First, Pointers.Second);
               Demand
                 (Self, Run_IO (Self, BAR),
                  (if Writing then "writing" else "reading")
                  & Positive'Image (Blocks_Now) & " blocks at"
                  & U64'Image (Block));

               if not Writing then
                  Data (Data'First + Done .. Data'First + Done + Now - 1) :=
                    Staging;
               end if;

               Done := Done + Now;
               Block := Block + U64 (Blocks_Now);
            end;
         end loop;
      end;
   end Transfer;

   --------------
   -- Read --
   --------------

   procedure Read
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      Into        : out Byte_Sequence)
   is
   begin
      Transfer (Self, BAR, First_Block, Into, Writing => False);
   end Read;

   ---------------
   -- Write --
   ---------------

   procedure Write
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      From        : Byte_Sequence)
   is
      Copy : Byte_Sequence := From;
   begin
      --  Transfer works in place for reads, so writes hand it a copy
      --  rather than the interface promising less than it means.
      Transfer (Self, BAR, First_Block, Copy, Writing => True);
   end Write;

   ---------------
   -- Flush --
   ---------------

   procedure Flush (Self : in out Volume; BAR : Regions.Window) is
   begin
      Write_Simple_Command
        (Self.IO_Sub, Self.IO_Slot, Self.Next_ID, Opcode_Flush,
         Self.Namespace);
      Demand (Self, Run_IO (Self, BAR), "flushing");
   end Flush;

   --------------
   -- Zero --
   --------------

   procedure Zero
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      Blocks      : Positive)
   is
   begin
      Write_Block_Range_Command
        (Self.IO_Sub, Self.IO_Slot, Self.Next_ID, Opcode_Write_Zeroes,
         Self.Namespace, First_Block, Blocks);
      Demand
        (Self, Run_IO (Self, BAR),
         "zeroing" & Positive'Image (Blocks) & " blocks at"
         & U64'Image (First_Block));
   end Zero;

   -----------------
   -- Discard --
   -----------------

   procedure Discard
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      Blocks      : Positive)
   is
   begin
      Write_Deallocate_Range (Self.List_Host, 0, First_Block, Blocks);
      Write_Deallocate_Command
        (Self.IO_Sub, Self.IO_Slot, Self.Next_ID, Self.Namespace, 1,
         Self.List_At);
      Demand
        (Self, Run_IO (Self, BAR),
         "discarding" & Positive'Image (Blocks) & " blocks at"
         & U64'Image (First_Block));
   end Discard;

end Flyology_VFIO_QEMU.NVMe.Blocks;
