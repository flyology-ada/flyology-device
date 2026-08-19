with System;

--  An NVMe namespace as a thing you read and write bytes on.
--
--  Everything else in this package writes commands. A caller has to know
--  that a block count goes in one less than the real number, that a buffer
--  crossing a page boundary needs a second pointer meaning something
--  different from the first, that a queue has a phase bit and a doorbell
--  and a slot that wraps. That knowledge is the point of the layer below
--  and it is not what someone storing bytes on a disk wants to hold.
--
--  So this is the layer that spends it. Open brings the controller up and
--  makes a queue pair; Read and Write move whole byte sequences of any
--  length; the transfer rules, the chunking, and the page lists happen
--  underneath. What is left in the interface is a block size, a number of
--  blocks, and the two operations.
--
--  It is still a harness. There is one queue pair rather than one per core,
--  completions are waited for rather than collected, and every operation is
--  synchronous. What it demonstrates is that the command layer composes
--  into something usable, and that the addresses it programs are right —
--  which a caller finds out by reading back what it wrote.
--
--  A Volume does not close itself. Stopping a controller means writing to
--  its register window, and a Volume holding a reference to a window the
--  language cannot prove outlives it is exactly the arrangement this
--  repository refuses elsewhere. The window is therefore passed to each
--  operation, and Close is explicit.
package Flyology_VFIO_QEMU.NVMe.Blocks is

   --  Bytes as a caller holds them, in ordinary memory.
   type Byte_Sequence is array (Natural range <>) of U8;

   --  A namespace that has been brought up and can be read and written.
   type Volume is tagged limited private;

   --  The smallest scratch area a Volume can be opened on.
   --
   --  Four queues, an identify buffer, and a page list take a page each;
   --  what remains is the transfer buffer, and a transfer buffer of one
   --  page would make every read a single-page read and quietly stop
   --  exercising the page lists this exists to get right.
   Minimum_Scratch_Bytes : constant := 32 * 1024;

   --  Brings the controller up and prepares one namespace for use.
   --
   --  The scratch area must be host memory already mapped for the device to
   --  read and write, and Scratch_At must be the device address of the same
   --  memory. Those being the same address is the mistake this whole
   --  repository is arranged around; here they are two parameters so that
   --  passing one twice does not typecheck into something plausible.
   --
   --  @param Self The volume to open
   --  @param BAR The controller's mapped register window
   --  @param Scratch Host address of the working memory
   --  @param Scratch_At Device address of that same memory
   --  @param Bytes How large the working memory is
   --  @param Namespace Which namespace to prepare
   --  @exception Device_Misbehaved The controller refused part of the
   --    bring-up, or the namespace reports a shape this cannot use
   procedure Open
     (Self       : in out Volume;
      BAR        : Regions.Window;
      Scratch    : System.Address;
      Scratch_At : U64;
      Bytes      : Positive;
      Namespace  : Namespace_Identifier := 1)
     with Pre => Bytes >= Minimum_Scratch_Bytes;

   --  Stops the controller and forgets the queues.
   --  @param Self The volume to close
   --  @param BAR The controller's mapped register window
   procedure Close (Self : in out Volume; BAR : Regions.Window);

   --  Whether the volume has been opened and not closed.
   --  @param Self The volume
   --  @return True while it is usable
   function Is_Open (Self : Volume) return Boolean;

   --  How many bytes one block holds.
   --  @param Self The volume
   --  @return The block size
   function Block_Bytes (Self : Volume) return Positive
     with Pre => Self.Is_Open;

   --  How many blocks the namespace holds.
   --  @param Self The volume
   --  @return The block count
   function Block_Count (Self : Volume) return U64
     with Pre => Self.Is_Open;

   --  How many bytes the namespace holds altogether.
   --  @param Self The volume
   --  @return The capacity in bytes
   function Capacity_Bytes (Self : Volume) return U64
     with Pre => Self.Is_Open;

   --  The serial number the controller reports.
   --  @param Self The volume
   --  @return The serial, trailing blanks removed
   function Serial (Self : Volume) return String
     with Pre => Self.Is_Open;

   --  The model name the controller reports.
   --  @param Self The volume
   --  @return The model, trailing blanks removed
   function Model (Self : Volume) return String
     with Pre => Self.Is_Open;

   --  How many bytes one command moves, at most.
   --
   --  The smaller of what the controller will accept and what fits in the
   --  scratch area. Read and Write are not limited by it — they issue as
   --  many commands as they need — but a caller measuring throughput wants
   --  to know how many that will be.
   --
   --  @param Self The volume
   --  @return The largest single transfer in bytes
   function Largest_Transfer (Self : Volume) return Positive
     with Pre => Self.Is_Open;

   --  Reads blocks into ordinary memory.
   --
   --  The length must be a whole number of blocks, which is the one thing
   --  a block device cannot be talked out of.
   --
   --  @param Self The volume
   --  @param BAR The controller's mapped register window
   --  @param First_Block Where to start reading
   --  @param Into Where to put the data; its length sets how much is read
   --  @exception Device_Misbehaved The controller refused
   --  @exception Device_Misused The length is not a whole number of blocks,
   --    or the range runs off the end
   procedure Read
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      Into        : out Byte_Sequence)
     with Pre => Self.Is_Open;

   --  Writes blocks from ordinary memory.
   --
   --  @param Self The volume
   --  @param BAR The controller's mapped register window
   --  @param First_Block Where to start writing
   --  @param From The data; its length sets how much is written
   --  @exception Device_Misbehaved The controller refused
   --  @exception Device_Misused The length is not a whole number of blocks,
   --    or the range runs off the end
   procedure Write
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      From        : Byte_Sequence)
     with Pre => Self.Is_Open;

   --  Asks the controller to commit anything it is holding.
   --  @param Self The volume
   --  @param BAR The controller's mapped register window
   --  @exception Device_Misbehaved The controller refused
   procedure Flush (Self : in out Volume; BAR : Regions.Window)
     with Pre => Self.Is_Open;

   --  Writes zeroes without sending any.
   --
   --  The controller is told what to store rather than given it, so this
   --  moves no data across the bus however many blocks it covers.
   --
   --  @param Self The volume
   --  @param BAR The controller's mapped register window
   --  @param First_Block Where to start
   --  @param Blocks How many blocks to zero
   --  @exception Device_Misbehaved The controller refused
   procedure Zero
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      Blocks      : Positive)
     with Pre => Self.Is_Open;

   --  Says a range of blocks is no longer needed.
   --
   --  What the controller then does with them is its own business: the
   --  specification lets it keep them, forget them, or return zeroes, and a
   --  caller that depends on which has misread it.
   --
   --  @param Self The volume
   --  @param BAR The controller's mapped register window
   --  @param First_Block Where to start
   --  @param Blocks How many blocks to give up
   --  @exception Device_Misbehaved The controller refused
   procedure Discard
     (Self        : in out Volume;
      BAR         : Regions.Window;
      First_Block : U64;
      Blocks      : Positive)
     with Pre => Self.Is_Open;

   --  The status the last command returned.
   --
   --  Zero after anything that succeeded. An operation that fails raises
   --  rather than returning, so this is for a caller that caught the
   --  exception and wants the number.
   --
   --  @param Self The volume
   --  @return The raw status field
   function Last_Status (Self : Volume) return U16;

private

   --  Sixteen entries is a queue small enough to fit a page several times
   --  over and deep enough that the slot arithmetic wraps during an
   --  ordinary run rather than only in a test written to make it.
   --
   --  That was written before the arithmetic wrapped. It did not: the
   --  doorbell was reduced modulo this number and the slot itself was not,
   --  so the seventeenth command on a queue was written past the end of
   --  the ring while the doorbell told the controller the tail had come
   --  round to zero — where a stale command was still sitting, and was run
   --  again. Both of this crate's block tests sat one or two commands
   --  under that, which is why nothing here ever showed it.
   Queue_Entries : constant := 16;

   IO_Queue : constant Queue_Identifier := 1;

   type Volume is tagged limited record
      Opened       : Boolean := False;
      Namespace    : Namespace_Identifier := 1;
      Stride       : Positive := 1;
      Page_Bytes   : Positive := 4096;
      Block_Size   : Positive := 512;
      Blocks       : U64 := 0;
      Largest      : Positive := 4096;
      Admin_Sub    : Queue_Location;
      Admin_Comp   : Queue_Location;
      IO_Sub       : Queue_Location;
      IO_Comp      : Queue_Location;
      List_Host    : System.Address := System.Null_Address;
      List_At      : U64 := 0;
      Buffer_Host  : System.Address := System.Null_Address;
      Buffer_At    : U64 := 0;
      Buffer_Bytes : Positive := 4096;
      --  Each queue's next slot, kept inside the ring, and the phase bit
      --  its next completion will carry.
      --
      --  The controller never clears a completion entry; it flips one bit
      --  each time it comes round again, and a reader that expects the
      --  same value for ever accepts the previous lap's completion as this
      --  lap's. So the phase inverts whenever the slot returns to zero,
      --  and both queues carry their own because they wrap at their own
      --  rates.
      Admin_Slot   : Natural := 0;
      Admin_Phase  : Boolean := True;
      IO_Slot      : Natural := 0;
      IO_Phase     : Boolean := True;
      Next_ID      : U16 := 1;
      Status       : U16 := 0;
      --  Where the register window was when this volume was opened.
      --
      --  Every operation takes the window again, which is what keeps a
      --  Volume from holding a reference the language cannot vouch for —
      --  and leaves nothing stopping the wrong window being passed. Two
      --  controllers of one model is a case this harness creates on
      --  purpose, and handing one volume the other's registers would ring
      --  a doorbell on a device that never had the queue, corrupting both.
      Window_Base  : System.Address := System.Null_Address;
      Serial_Text  : String (1 .. 20) := [others => ' '];
      Model_Text   : String (1 .. 40) := [others => ' '];
   end record;

   function Is_Open (Self : Volume) return Boolean is (Self.Opened);
   function Block_Bytes (Self : Volume) return Positive is (Self.Block_Size);
   function Block_Count (Self : Volume) return U64 is (Self.Blocks);
   function Capacity_Bytes (Self : Volume) return U64 is
     (Self.Blocks * U64 (Self.Block_Size));
   function Largest_Transfer (Self : Volume) return Positive is (Self.Largest);
   function Last_Status (Self : Volume) return U16 is (Self.Status);

end Flyology_VFIO_QEMU.NVMe.Blocks;
