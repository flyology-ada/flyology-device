with Flyology_DMA;
with Flyology_VFIO.Regions;
with Interfaces;
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

end Flyology_VFIO_QEMU.NVMe;
