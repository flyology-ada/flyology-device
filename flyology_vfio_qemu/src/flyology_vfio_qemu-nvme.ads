with Flyology_DMA;
with Flyology_VFIO.Regions;
with Interfaces;
use type Interfaces.Unsigned_8;
use type Interfaces.Unsigned_16;
use type Interfaces.Unsigned_32;
use type Interfaces.Unsigned_64;
with System;

--  An NVMe controller, driven far enough to make it answer.
--
--  This device is here for what it makes the layers below prove. edu
--  demonstrates that a device can follow an I/O virtual address; an NVMe
--  controller demonstrates it four times over in one operation, in both
--  directions, against addresses the controller was told about through
--  three separate registers rather than one.
--
--  Bringing it up: the controller is disabled, its admin queues are pointed
--  at memory the IOMMU has been programmed for, and it is enabled again. It
--  then reads its submission queue by DMA, writes its completion queue by
--  DMA, and writes the four kibibytes of Identify data by DMA. A driver
--  that got any of those addresses wrong gets silence and a controller that
--  never becomes ready.
--
--  It also brings register widths this repository had not touched: a
--  sixty-four bit base address register, sixty-four bit registers within
--  it, and a doorbell whose position depends on a stride the controller
--  itself reports.
--
--  What is deliberately not here: namespaces, I/O queues, and reading or
--  writing a single block. Those are a storage driver, and this is a
--  harness. The admin queue is the smallest thing that proves the point.
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

   --  Where a queue lives, as both addresses of the same bytes.
   --
   --  @field Host Where this process writes the entries
   --  @field Device The address the controller is given
   --  @field Entries How many entries the queue holds
   type Queue_Location is record
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
      CDW12      : U32 := 0);

   --  Admin opcode: describe the controller or a namespace.
   Opcode_Identify : constant U8 := 16#06#;

   --  Admin opcode: create an I/O submission queue.
   Opcode_Create_Submission_Queue : constant U8 := 16#01#;

   --  Admin opcode: create an I/O completion queue.
   Opcode_Create_Completion_Queue : constant U8 := 16#05#;

   --  Admin opcode: remove an I/O submission queue.
   Opcode_Delete_Submission_Queue : constant U8 := 16#00#;

   --  Admin opcode: remove an I/O completion queue.
   Opcode_Delete_Completion_Queue : constant U8 := 16#04#;

   --  I/O opcode: write blocks.
   Opcode_Write : constant U8 := 16#01#;

   --  I/O opcode: read blocks.
   Opcode_Read : constant U8 := 16#02#;

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
      Queue  : Natural;
      Tail   : Natural);

   --  Tells the controller that a completion has been consumed.
   --  @param BAR The controller's mapped registers
   --  @param Stride The doorbell stride from the capabilities register
   --  @param Queue Which queue pair, zero for the admin queue
   --  @param Head The next completion not yet consumed
   procedure Ring_Completion_Doorbell
     (BAR    : Regions.Window;
      Stride : Positive;
      Queue  : Natural;
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
      Namespace      : U32;
      Result_Address : U64);

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
      Queue_Number : Positive;
      Entries      : Positive;
      Address      : U64);

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
      Queue_Number     : Positive;
      Completion_Number : Positive;
      Entries          : Positive;
      Address          : U64);

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
      Opcode       : U8;
      Queue_Number : Positive);

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
      Opcode      : U8;
      Namespace   : U32;
      First_Block : U64;
      Blocks      : Positive;
      Address     : U64);

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
