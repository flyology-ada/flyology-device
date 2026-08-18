with Flyology_DMA;
with Flyology_VFIO.Regions;
with Interfaces;
use type Interfaces.Unsigned_8;
use type Interfaces.Unsigned_16;
use type Interfaces.Unsigned_32;
use type Interfaces.Unsigned_64;
with System;

--  An NVMe controller, driven as a disk.
--
--  This device is here for what it makes the layers below prove. edu
--  demonstrates that a device can follow an I/O virtual address; an NVMe
--  controller demonstrates it several times over in a single operation, in
--  both directions, against addresses it was told about through three
--  separate registers rather than one.
--
--  Bringing it up: the controller is disabled, its admin queues are pointed
--  at memory the IOMMU has been programmed for, and it is enabled again. It
--  then reads its submission queue by DMA, writes its completion queue by
--  DMA, and writes whatever the command asked for by DMA. A driver that got
--  any of those addresses wrong gets silence and a controller that never
--  becomes ready.
--
--  From there it is used rather than merely interrogated: the namespace is
--  described, an I/O queue pair is created, and blocks are written and read
--  back. The command set reaches Flush, Compare, Verify, Write Zeroes,
--  Dataset Management and Abort, and transfers larger than two pages go
--  through a pointer list, because one command carries only two pointers
--  and getting the third page wrong drops it silently.
--
--  It also brings register widths this repository had not touched: a
--  sixty-four bit base address register, sixty-four bit registers within
--  it, and a doorbell whose position depends on a stride the controller
--  reports itself.
--
--  What is deliberately not here: everything a storage driver would need
--  and a harness does not. There is no namespace management, no more than
--  one queue pair, no interrupt-driven completion — the queues are polled —
--  and no attempt to be fast. Flyology_VFIO_QEMU.NVMe exists to make the
--  layers below it prove themselves, not to store anything anyone wants
--  back.
package Flyology_VFIO_QEMU.NVMe is

   package DMA renames Flyology_DMA;
   package Regions renames Flyology_VFIO.Regions;

   --  QEMU's own vendor identifier, shared with its other devices.
   Vendor_ID : constant U16 := 16#1B36#;

   --  The NVMe controller.
   Device_ID : constant U16 := 16#0010#;

   --  The controller's registers, always the first region.
   Register_BAR : constant Regions.Region_Index := 0;

   ---------------------------------------------------------------------
   --  Controller registers
   ---------------------------------------------------------------------

   --  Capabilities, sixty-four bits wide.
   Capabilities_Register : constant := 16#00#;

   --  The version of the specification this controller implements.
   Version_Register : constant := 16#08#;

   --  Configuration, including the enable bit.
   Configuration_Register : constant := 16#14#;

   --  Status, including the ready bit and the fatal-error bit.
   Status_Register : constant := 16#1C#;

   --  How many entries each admin queue has.
   Admin_Queue_Attributes_Register : constant := 16#24#;

   --  Where the admin submission queue lives, as the controller sees it.
   Admin_Submission_Queue_Register : constant := 16#28#;

   --  Where the admin completion queue lives, as the controller sees it.
   Admin_Completion_Queue_Register : constant := 16#30#;

   --  Where the doorbells begin. Which doorbell is which depends on the
   --  stride the controller reports in its capabilities, so a driver that
   --  assumes a stride works on some controllers and not others.
   Doorbell_Base : constant := 16#1000#;

   --  Set in the configuration register to enable the controller.
   Configuration_Enable : constant U32 := 16#01#;

   --  Set in the status register once the controller is ready for commands.
   Status_Ready : constant U32 := 16#01#;

   --  Set in the status register when the controller has given up.
   Status_Fatal : constant U32 := 16#02#;

   ---------------------------------------------------------------------
   --  Capability fields
   ---------------------------------------------------------------------

   --  The most entries an admin queue may have.
   --  @param Capabilities A reading of the capabilities register
   --  @return Maximum queue entries, counted from one
   function Maximum_Queue_Entries (Capabilities : U64) return Positive
     is (Positive (Capabilities and 16#FFFF#) + 1);

   --  How far apart consecutive doorbells are, in bytes.
   --  @param Capabilities A reading of the capabilities register
   --  @return The stride in bytes, always a power of two at least four
   function Doorbell_Stride (Capabilities : U64) return Positive
     is (4 * 2 ** Natural (Interfaces.Shift_Right (Capabilities, 32)
                           and 16#F#));

   --  How long the controller may take to become ready, in milliseconds.
   --  @param Capabilities A reading of the capabilities register
   --  @return The timeout the specification allows it
   function Ready_Timeout_Milliseconds (Capabilities : U64) return Natural
     is (500 * Natural (Interfaces.Shift_Right (Capabilities, 24)
                        and 16#FF#));

   --  The smallest memory page size the controller supports, in bytes.
   --  @param Capabilities A reading of the capabilities register
   --  @return The minimum page size
   function Minimum_Page_Size (Capabilities : U64) return Positive
     is (2 ** (12 + Natural (Interfaces.Shift_Right (Capabilities, 48)
                             and 16#F#)));

   --  The major part of the version register.
   --  @param Version A reading of the version register
   --  @return The major version
   function Major_Version (Version : U32) return Natural
     is (Natural (Interfaces.Shift_Right (Version, 16)));

   --  The minor part of the version register.
   --  @param Version A reading of the version register
   --  @return The minor version
   function Minor_Version (Version : U32) return Natural
     is (Natural (Interfaces.Shift_Right (Version, 8) and 16#FF#));

   ---------------------------------------------------------------------
   --  Bringing the controller up
   ---------------------------------------------------------------------

   --  How large one submission queue entry is.
   Submission_Entry_Bytes : constant := 64;

   --  How large one completion queue entry is.
   Completion_Entry_Bytes : constant := 16;

   --  How large the Identify data structure is.
   Identify_Bytes : constant := 4096;

   ---------------------------------------------------------------------
   --  Opcodes, and why they are two types rather than one
   ---------------------------------------------------------------------

   --  The same opcode number means different things depending on which
   --  queue it is sent to, and the numbers that collide are the ones a
   --  driver uses constantly. Zero is Delete I/O Submission Queue on the
   --  admin queue and Flush on a namespace queue. One is Create I/O
   --  Submission Queue, or Write. Two is Get Log Page, or Read.
   --
   --  Nothing in the number distinguishes them, so sending a namespace
   --  opcode to the admin queue is a command that runs and does something
   --  else entirely. The two are therefore distinct types, and the queue
   --  each may be sent to is fixed by the queue's own kind, so the
   --  compiler refuses the mistake rather than the controller obeying it.
   --
   --  This is the same argument, and the same remedy, as the distinct
   --  descriptor types in Flyology_VFIO: several VFIO request numbers mean
   --  one thing on a container and another on a device.

   --  A command sent to the admin queue.
   type Admin_Opcode is new U8;

   --  A command sent to a namespace queue.
   type IO_Opcode is new U8;

   --  Which feature a Get or Set Features command names.
   type Feature_Identifier is new U8;

   --  Which log a Get Log Page command names.
   type Log_Identifier is new U8;

   --  Which namespace a command applies to.
   type Namespace_Identifier is new U32;

   --  Every namespace at once, where a command allows it.
   All_Namespaces : constant Namespace_Identifier := 16#FFFF_FFFF#;

   --  No namespace, which is what a controller-scope command takes.
   No_Namespace : constant Namespace_Identifier := 0;

   --  Which queue pair. Zero is the admin pair, which exists from the
   --  moment the controller is enabled and is never created or deleted.
   type Queue_Identifier is new Natural range 0 .. 65_535;

   --  The admin queue pair.
   Admin_Queue : constant Queue_Identifier := 0;

   --  What a queue is for.
   --  @enum Admin The pair the controller is configured through
   --  @enum Namespace_IO A pair that carries reads and writes
   type Queue_Kind is (Admin, Namespace_IO);

   --  Where a queue lives, as both addresses of the same bytes.
   --
   --  The kind is a discriminant rather than a field so that it cannot be
   --  changed after the queue is built, and so that the commands below can
   --  require the right one.
   --
   --  @field Kind Whether this is the admin pair or a namespace pair
   --  @field Host Where this process writes the entries
   --  @field Device The address the controller is given
   --  @field Entries How many entries the queue holds
   type Queue_Location (Kind : Queue_Kind := Admin) is record
      Host    : System.Address;
      Device  : U64;
      Entries : Positive;
   end record;

   --  Disables the controller and waits for it to stop.
   --
   --  A controller must be disabled before its admin queues can be moved,
   --  and it is disabled at reset anyway; doing it explicitly means the
   --  sequence works whatever state the controller was left in.
   --
   --  @param BAR The controller's mapped registers
   --  @param Attempts How many times to poll before giving up
   --  @exception Device_Misbehaved The controller did not become not-ready
   procedure Disable (BAR : Regions.Window; Attempts : Positive := 20_000);

   --  Points the controller at admin queues and enables it.
   --
   --  Both queue addresses are I/O virtual addresses, and the controller
   --  reaches them by DMA. Enabling it is therefore the first moment
   --  anything checks whether those addresses were programmed correctly,
   --  and a controller that never becomes ready is what a wrong one looks
   --  like.
   --
   --  @param BAR The controller's mapped registers
   --  @param Submission Where the admin submission queue lives
   --  @param Completion Where the admin completion queue lives
   --  @param Attempts How many times to poll before giving up
   --  @exception Device_Misbehaved The controller did not become ready, or
   --    reported a fatal error
   procedure Enable
     (BAR        : Regions.Window;
      Submission : Queue_Location;
      Completion : Queue_Location;
      Attempts   : Positive := 20_000);

   --  Whether the controller is ready for commands.
   --  @param BAR The controller's mapped registers
   --  @return True when the ready bit is set
   function Is_Ready (BAR : Regions.Window) return Boolean;

   --  Writes an arbitrary command into a submission queue slot.
   --
   --  Every command below is built on this. The parameter names are the
   --  specification's, because a reader checking this against the
   --  specification should not have to translate: DPTR is the data pointer,
   --  and CDW10 upwards are the command-specific words whose meaning
   --  depends entirely on the opcode.
   --
   --  @param Submission Where the submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Opcode Which command
   --  @param Identifier The command identifier, echoed in the completion
   --  @param Namespace Which namespace, or zero where none applies
   --  @param DPTR1 First data pointer, a device address
   --  @param DPTR2 Second data pointer, a device address
   --  @param CDW10 Command word ten
   --  @param CDW11 Command word eleven
   --  @param CDW12 Command word twelve
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
      CDW12      : U32 := 0)
     with Pre => Submission.Kind = Admin;

   --  The same, for a command sent to a namespace queue.
   --
   --  @param Submission Where the namespace submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Opcode Which command
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace
   --  @param DPTR1 First data pointer, a device address
   --  @param DPTR2 Second data pointer, a device address
   --  @param CDW10 Command word ten
   --  @param CDW11 Command word eleven
   --  @param CDW12 Command word twelve
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
      CDW12      : U32 := 0)
     with Pre => Submission.Kind = Namespace_IO;

   --  Admin opcode: describe the controller or a namespace.
   Opcode_Identify : constant Admin_Opcode := 16#06#;

   --  Admin opcode: create an I/O submission queue.
   Opcode_Create_Submission_Queue : constant Admin_Opcode := 16#01#;

   --  Admin opcode: create an I/O completion queue.
   Opcode_Create_Completion_Queue : constant Admin_Opcode := 16#05#;

   --  Admin opcode: remove an I/O submission queue.
   Opcode_Delete_Submission_Queue : constant Admin_Opcode := 16#00#;

   --  Admin opcode: remove an I/O completion queue.
   Opcode_Delete_Completion_Queue : constant Admin_Opcode := 16#04#;

   --  I/O opcode: write blocks.
   Opcode_Write : constant IO_Opcode := 16#01#;

   --  I/O opcode: read blocks.
   Opcode_Read : constant IO_Opcode := 16#02#;

   --  Admin opcode: report a feature's current value.
   Opcode_Get_Features : constant Admin_Opcode := 16#0A#;

   --  Admin opcode: change a feature.
   Opcode_Set_Features : constant Admin_Opcode := 16#09#;

   --  Admin opcode: read one of the controller's logs.
   Opcode_Get_Log_Page : constant Admin_Opcode := 16#02#;

   --  I/O opcode: commit written data to stable storage.
   Opcode_Flush : constant IO_Opcode := 16#00#;

   --  I/O opcode: write zeroes without transferring them.
   Opcode_Write_Zeroes : constant IO_Opcode := 16#08#;

   --  I/O opcode: compare stored data against a buffer.
   Opcode_Compare : constant IO_Opcode := 16#05#;

   --  I/O opcode: check that blocks can be read, without transferring them.
   Opcode_Verify : constant IO_Opcode := 16#0C#;

   --  Admin opcode: give up on a command already submitted.
   Opcode_Abort : constant Admin_Opcode := 16#08#;

   --  I/O opcode: mark blocks as holding data that cannot be recovered, so
   --  that reading them fails. The only way to make a read fail on demand,
   --  and therefore the only way to test that a driver notices.
   Opcode_Write_Uncorrectable : constant IO_Opcode := 16#04#;

   --  I/O opcode: tell the controller what a range of blocks is for, or
   --  that it is no longer needed.
   Opcode_Dataset_Management : constant IO_Opcode := 16#09#;

   --  An opcode no command set defines, for checking that a controller
   --  refuses what it does not implement rather than ignoring it.
   Opcode_Undefined : constant Admin_Opcode := 16#FE#;

   --  Feature: how many I/O queues the controller will allow.
   --
   --  A real driver asks for this before creating any, because the answer
   --  can be fewer than it asked for and creating more than were granted
   --  fails one queue at a time.
   Feature_Number_Of_Queues : constant Feature_Identifier := 16#07#;

   --  Feature: whether the controller has a volatile write cache, which
   --  decides whether Flush means anything.
   Feature_Volatile_Write_Cache : constant Feature_Identifier := 16#06#;

   --  Feature: how long the controller retries before giving up.
   Feature_Error_Recovery : constant Feature_Identifier := 16#05#;

   --  Feature: how the controller batches completions before interrupting.
   Feature_Interrupt_Coalescing : constant Feature_Identifier := 16#08#;

   --  Feature: how the controller arbitrates between submission queues.
   Feature_Arbitration : constant Feature_Identifier := 16#00#;

   --  Feature: the controller's power state.
   Feature_Power_Management : constant Feature_Identifier := 16#01#;

   --  Feature: which asynchronous events the controller may report.
   Feature_Async_Event_Configuration : constant Feature_Identifier := 16#0B#;

   --  A feature identifier outside anything defined, for checking refusal.
   Feature_Undefined : constant Feature_Identifier := 16#7E#;

   --  Log: the errors the controller has recorded.
   Log_Error_Information : constant Log_Identifier := 16#01#;

   --  Log: the controller's health, including how much has been read and
   --  written through it.
   Log_Health_Information : constant Log_Identifier := 16#02#;

   --  Log: which firmware is in which slot.
   Log_Firmware_Slot : constant Log_Identifier := 16#03#;

   --  Which structure Identify should return: the namespaces that exist.
   Identify_Active_Namespaces : constant U32 := 2;

   --  Which structure Identify should return: how each namespace is named.
   Identify_Namespace_Descriptors : constant U32 := 3;

   --  Set in the configuration register to ask for an orderly shutdown.
   Configuration_Shutdown_Normal : constant U32 := 2 ** 14;

   --  What the status register reports about a shutdown in its third and
   --  fourth bits: zero for none in progress, one for occurring, two for
   --  complete.
   function Shutdown_State (Status : U32) return Natural
     is (Natural (Interfaces.Shift_Right (Status, 2) and 3));

   --  Which structure Identify should return: the controller itself.
   Identify_Controller : constant U32 := 1;

   --  Which structure Identify should return: one namespace.
   Identify_Namespace : constant U32 := 0;

   --  Writes an Identify Controller command into a submission queue slot.
   --
   --  @param Submission Where the submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier, echoed in the completion
   --  @param Result_Address The device address to deliver the data to
   procedure Write_Identify_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Result_Address : U64);

   --  Tells the controller that a submission queue entry is ready.
   --
   --  A release store, because every byte of the command must be visible to
   --  the controller before it is told to look. This is the doorbell this
   --  whole repository's ordered accessors exist for.
   --
   --  @param BAR The controller's mapped registers
   --  @param Stride The doorbell stride from the capabilities register
   --  @param Queue Which queue pair, zero for the admin queue
   --  @param Tail The next slot the controller has not been given
   procedure Ring_Submission_Doorbell
     (BAR    : Regions.Window;
      Stride : Positive;
      Queue  : Queue_Identifier;
      Tail   : Natural);

   --  Tells the controller that a completion has been consumed.
   --  @param BAR The controller's mapped registers
   --  @param Stride The doorbell stride from the capabilities register
   --  @param Queue Which queue pair, zero for the admin queue
   --  @param Head The next completion not yet consumed
   procedure Ring_Completion_Doorbell
     (BAR    : Regions.Window;
      Stride : Positive;
      Queue  : Queue_Identifier;
      Head   : Natural);

   --  What the controller reported about one command.
   --
   --  @field Identifier The command identifier it was given
   --  @field Status Zero when the command succeeded
   --  @field Phase The phase bit, which is how a new entry is recognised
   type Completion is record
      Identifier : U16;
      Status     : U16;
      Phase      : Boolean;
   end record;

   --  Reads one completion queue entry.
   --  @param Queue Where the completion queue lives
   --  @param Slot Which entry to read, from zero
   --  @return What the controller wrote there
   function Read_Completion
     (Queue : Queue_Location; Slot : Natural) return Completion;

   --  Waits for the controller to complete a command.
   --
   --  A completion queue entry is recognised by its phase bit differing
   --  from the previous pass over the queue, because the controller never
   --  clears entries: it flips the bit each time it wraps. Waiting for the
   --  bit rather than for the memory to change is what makes a queue
   --  reusable without clearing it.
   --
   --  @param Queue Where the completion queue lives
   --  @param Slot Which entry to watch
   --  @param Expected_Phase The phase that marks an entry as new
   --  @param Attempts How many times to poll before giving up
   --  @return The completion
   --  @exception Device_Misbehaved Nothing arrived in time
   function Await_Completion
     (Queue          : Queue_Location;
      Slot           : Natural;
      Expected_Phase : Boolean;
      Attempts       : Positive := 20_000) return Completion;

   --  Writes an Identify Namespace command.
   --  @param Submission Where the submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace to describe
   --  @param Result_Address The device address to deliver the data to
   procedure Write_Identify_Namespace_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Namespace      : Namespace_Identifier;
      Result_Address : U64)
     with Pre => Submission.Kind = Admin;

   --  Writes a command creating an I/O completion queue.
   --
   --  The completion queue must exist before the submission queue that
   --  reports into it; the controller rejects the pair in the other order,
   --  which is one of the few orderings NVMe states outright.
   --
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Queue_Number Which queue to create, from one
   --  @param Entries How many entries it holds
   --  @param Address Where it lives, as a device address
   procedure Write_Create_Completion_Queue_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Queue_Number : Queue_Identifier;
      Entries      : Positive;
      Address      : U64)
     with Pre => Submission.Kind = Admin
                 and then Queue_Number /= Admin_Queue;

   --  Writes a command creating an I/O submission queue.
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Queue_Number Which queue to create, from one
   --  @param Completion_Number Which completion queue it reports into
   --  @param Entries How many entries it holds
   --  @param Address Where it lives, as a device address
   procedure Write_Create_Submission_Queue_Command
     (Submission       : Queue_Location;
      Slot             : Natural;
      Identifier       : U16;
      Queue_Number      : Queue_Identifier;
      Completion_Number : Queue_Identifier;
      Entries           : Positive;
      Address           : U64)
     with Pre => Submission.Kind = Admin
                 and then Queue_Number /= Admin_Queue
                 and then Completion_Number /= Admin_Queue;

   --  Writes a command removing a queue.
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Opcode Which of the two delete opcodes
   --  @param Queue_Number Which queue to remove
   procedure Write_Delete_Queue_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Opcode       : Admin_Opcode;
      Queue_Number : Queue_Identifier)
     with Pre => Submission.Kind = Admin
                 and then Queue_Number /= Admin_Queue;

   --  Writes a command reading or writing blocks.
   --
   --  One data pointer covers a transfer up to a page; a second covers the
   --  page after it. Anything larger needs a list, which this harness has
   --  no reason to build.
   --
   --  @param Submission Where the I/O submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Opcode Read or write
   --  @param Namespace Which namespace
   --  @param First_Block The first logical block
   --  @param Blocks How many blocks, counted from one
   --  @param Address Where the data lives, as a device address
   procedure Write_Block_Command
     (Submission  : Queue_Location;
      Slot        : Natural;
      Identifier  : U16;
      Opcode      : IO_Opcode;
      Namespace   : Namespace_Identifier;
      First_Block : U64;
      Blocks      : Positive;
      Address     : U64)
     with Pre => Submission.Kind = Namespace_IO;

   --  Writes a command reading or changing a feature.
   --
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Opcode Get or set
   --  @param Feature Which feature
   --  @param Value The value to set, ignored when getting
   --  @param Namespace Which namespace, where the feature is per-namespace
   procedure Write_Feature_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Identifier : U16;
      Opcode     : Admin_Opcode;
      Feature    : Feature_Identifier;
      Value      : U32 := 0;
      Namespace  : Namespace_Identifier := No_Namespace)
     with Pre => Submission.Kind = Admin;

   --  Writes a command reading one of the controller's logs.
   --
   --  The length is given in dwords minus one, which is the specification's
   --  convention and a reliable source of transfers one word short.
   --
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Log Which log
   --  @param Bytes How many bytes to read; a multiple of four
   --  @param Result_Address Where to deliver the log
   --  @param Namespace Which namespace, or all ones for the controller
   procedure Write_Log_Page_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Log            : Log_Identifier;
      Bytes          : Positive;
      Result_Address : U64;
      Namespace      : Namespace_Identifier := All_Namespaces)
     with Pre => Submission.Kind = Admin;

   --  Writes a command with no data transfer, such as Flush.
   --  @param Submission Where the submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Opcode Which command
   --  @param Namespace Which namespace
   procedure Write_Simple_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Identifier : U16;
      Opcode     : IO_Opcode;
      Namespace  : Namespace_Identifier)
     with Pre => Submission.Kind = Namespace_IO;

   --  Writes a command affecting blocks without transferring data, such as
   --  Write Zeroes or Verify.
   --  @param Submission Where the submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Opcode Which command
   --  @param Namespace Which namespace
   --  @param First_Block The first logical block
   --  @param Blocks How many blocks, counted from one
   procedure Write_Block_Range_Command
     (Submission  : Queue_Location;
      Slot        : Natural;
      Identifier  : U16;
      Opcode      : IO_Opcode;
      Namespace   : Namespace_Identifier;
      First_Block : U64;
      Blocks      : Positive)
     with Pre => Submission.Kind = Namespace_IO;

   --  Writes a command asking the controller to abandon another.
   --
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier This command's own identifier
   --  @param Target_Queue Which submission queue holds the command
   --  @param Target_Identifier The identifier of the command to abandon
   procedure Write_Abort_Command
     (Submission        : Queue_Location;
      Slot              : Natural;
      Identifier        : U16;
      Target_Queue      : Queue_Identifier;
      Target_Identifier : U16)
     with Pre => Submission.Kind = Admin;

   --  Writes a command telling the controller a range of blocks is no
   --  longer needed.
   --
   --  The range list is a structure in memory rather than fields in the
   --  command, because one command may name many ranges.
   --
   --  @param Submission Where the namespace submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace
   --  @param Ranges How many ranges the list holds
   --  @param List_Address Where the list lives, as a device address
   procedure Write_Deallocate_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Namespace    : Namespace_Identifier;
      Ranges       : Positive;
      List_Address : U64)
     with Pre => Submission.Kind = Namespace_IO and then Ranges <= 256;

   --  Fills in one entry of a deallocation range list.
   --
   --  Each entry is sixteen bytes: a context word, a block count, and the
   --  first block, in that order and all little-endian.
   --
   --  @param List Where the list lives
   --  @param Index Which entry, from zero
   --  @param First_Block The first block of the range
   --  @param Blocks How many blocks the range covers
   procedure Write_Deallocate_Range
     (List        : System.Address;
      Index       : Natural;
      First_Block : U64;
      Blocks      : Positive);

   --  The command-specific result the controller returned.
   --
   --  Get Features answers here rather than in a buffer, which is why the
   --  completion carries a value at all.
   --
   --  @param Queue Where the completion queue lives
   --  @param Slot Which entry to read
   --  @return The first word of the completion
   function Completion_Result
     (Queue : Queue_Location; Slot : Natural) return U32;

   ---------------------------------------------------------------------
   --  The Identify Controller structure
   ---------------------------------------------------------------------

   --  The vendor identifier the controller reports about itself.
   --  @param Data Address of the Identify data
   --  @return The vendor identifier
   function Identified_Vendor (Data : System.Address) return U16;

   --  The serial number, with trailing padding removed.
   --
   --  Worth reading because it is a value chosen outside this program, on
   --  the command line that started the machine, and recovered here only by
   --  the controller having successfully written four kibibytes into memory
   --  the IOMMU was programmed for.
   --
   --  @param Data Address of the Identify data
   --  @return The serial number
   function Identified_Serial (Data : System.Address) return String;

   --  The model name, with trailing padding removed.
   --  @param Data Address of the Identify data
   --  @return The model name
   function Identified_Model (Data : System.Address) return String;

   --  How many namespaces the controller has.
   --  @param Data Address of the Identify Controller data
   --  @return The namespace count
   function Identified_Namespace_Count (Data : System.Address) return U32;

   ---------------------------------------------------------------------
   --  The Identify Namespace structure
   ---------------------------------------------------------------------

   --  How many logical blocks the namespace holds.
   --  @param Data Address of the Identify Namespace data
   --  @return The block count
   function Namespace_Blocks (Data : System.Address) return U64;

   --  How large one logical block is, in bytes.
   --
   --  The namespace describes several possible formats and says which one
   --  is in use; the size is the base-two logarithm held in the format
   --  currently selected, which is not a number a driver may assume.
   --
   --  @param Data Address of the Identify Namespace data
   --  @return The block size in bytes
   function Namespace_Block_Bytes (Data : System.Address) return Positive;

end Flyology_VFIO_QEMU.NVMe;
