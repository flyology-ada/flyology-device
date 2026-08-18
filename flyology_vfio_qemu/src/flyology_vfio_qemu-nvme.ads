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
--  and a harness does not. Completions are polled rather than announced by
--  interrupt; a queue is whatever the caller built and nothing manages its
--  lifetime; nothing here is safe to call from two tasks; and a controller
--  that misbehaves raises rather than being recovered from. This package
--  exists to make the layers below it prove themselves, not to store
--  anything anyone wants back.
--
--  It does now create queue pairs beyond the first, bind them to interrupt
--  vectors, and manage namespaces — those were on the absent list until
--  the interesting failures turned out to live in them.
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

   --  Which MSI-X vector a completion queue signals, or none.
   type Interrupt_Selection is new Integer range -1 .. 2_047;

   --  Poll this queue rather than being interrupted about it.
   No_Interrupt : constant Interrupt_Selection := -1;

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

   --  Whether the controller supports command sets beyond the basic one.
   --
   --  A zoned namespace is addressed through a different I/O command set,
   --  and a controller enabled for the basic set alone answers Invalid
   --  Command Opcode to every zoned command — which looks exactly like a
   --  controller that does not implement them.
   --
   --  @param Capabilities A reading of the capabilities register
   --  @return True when more than the basic command set is available
   function Supports_Multiple_Command_Sets
     (Capabilities : U64) return Boolean
     is ((Interfaces.Shift_Right (Capabilities, 43) and 1) = 1);

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
   --  All_Command_Sets asks for every I/O command set the controller
   --  supports rather than the basic one alone. Without it a zoned
   --  namespace is unreachable and says so in a way indistinguishable from
   --  not existing.
   --
   --  @param Attempts How many times to poll before giving up
   --  @param All_Command_Sets Whether to select every supported I/O
   --    command set; ignored when the controller offers only the basic one
   --  @exception Device_Misbehaved The controller did not become ready, or
   --    reported a fatal error
   procedure Enable
     (BAR              : Regions.Window;
      Submission       : Queue_Location;
      Completion       : Queue_Location;
      Attempts         : Positive := 20_000;
      All_Command_Sets : Boolean := True);

   --  Asks the controller to shut down, and waits until it has.
   --
   --  Distinct from Disable, which stops the controller where it stands.
   --  A shutdown notification tells it to finish what it has and commit
   --  anything it was holding, and it reports progress in its own status
   --  register rather than simply going not-ready. A driver that disables
   --  without notifying may lose whatever a volatile write cache held.
   --
   --  @param BAR The controller's mapped registers
   --  @param Attempts How many times to poll before giving up
   --  @exception Device_Misbehaved The shutdown did not complete
   procedure Shut_Down (BAR : Regions.Window; Attempts : Positive := 20_000);

   --  How far a shutdown has got, as the status register reports it.
   --  @param BAR The controller's mapped registers
   --  @return Zero for none requested, one for in progress, two for done
   function Shutdown_Progress (BAR : Regions.Window) return Natural;

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
   --  @param CDW13 Command word thirteen
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
   --  @param CDW13 Command word thirteen
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

   --  I/O opcode: copy blocks within a namespace without routing the data
   --  through host memory.
   --
   --  The most demanding thing in the command set for the layers below it:
   --  the controller reads a descriptor list from one device address, reads
   --  the source blocks it names, and writes the destination blocks, all
   --  without the host seeing the data. Three separately programmed
   --  addresses have to be right and none of them can be checked by looking
   --  at what came back, because nothing comes back.
   --
   --  Shares its number with Directive Send, which is an admin command.
   --  The two never meet: an opcode means nothing without knowing which
   --  queue it was submitted to.
   Opcode_Copy : constant IO_Opcode := 16#19#;

   --  Admin opcode: tell the controller where its doorbells may be
   --  shadowed in host memory, so a driver can skip a register write when
   --  the controller has not fallen behind.
   Opcode_Doorbell_Buffer_Config : constant Admin_Opcode := 16#7C#;

   --  Admin opcode: read a directive's parameters.
   Opcode_Directive_Receive : constant Admin_Opcode := 16#1A#;

   --  Admin opcode: change a directive's parameters.
   --
   --  A directive is a side channel for telling the controller something
   --  about data it has not been given yet — which stream a write belongs
   --  to, so that data with a common lifetime is kept together and erased
   --  together. Receive reports which directives exist and which are
   --  switched on; Send switches one on.
   Opcode_Directive_Send : constant Admin_Opcode := 16#19#;

   --  Admin opcode: give up on a command already submitted.
   Opcode_Abort : constant Admin_Opcode := 16#08#;

   --  I/O opcode: mark blocks as holding data that cannot be recovered, so
   --  that reading them fails. The only way to make a read fail on demand,
   --  and therefore the only way to test that a driver notices.
   Opcode_Write_Uncorrectable : constant IO_Opcode := 16#04#;

   --  I/O opcode: tell the controller what a range of blocks is for, or
   --  that it is no longer needed.
   Opcode_Dataset_Management : constant IO_Opcode := 16#09#;

   --  Admin opcode: attach a namespace to a controller, or detach it.
   Opcode_Namespace_Attachment : constant Admin_Opcode := 16#15#;

   --  I/O opcode: write at whatever offset the zone has reached, and be
   --  told afterwards where that was. The point of a zoned namespace: many
   --  writers can append to one zone without agreeing a position first.
   --
   --  Note the number. It is 7Dh, near its two companions at 79h and 7Ah,
   --  and not 0Dh — which is what it gets mistaken for, because 0Dh sits
   --  where a reader skimming the low opcodes expects it and is defined by
   --  nothing at all.
   Opcode_Zone_Append : constant IO_Opcode := 16#7D#;

   --  I/O opcode: change a zone's state.
   Opcode_Zone_Send : constant IO_Opcode := 16#79#;

   --  I/O opcode: describe zones.
   Opcode_Zone_Receive : constant IO_Opcode := 16#7A#;

   --  What a Zone Management Send should do to the zone it names.
   --
   --  @enum Close Stop writing to it, keeping what is written
   --  @enum Finish Declare it full, whatever its write pointer says
   --  @enum Open Make it explicitly writable
   --  @enum Reset Empty it and return its write pointer to the start
   --  @enum Offline Take a full zone out of service
   type Zone_Action is (Close, Finish, Open, Reset, Offline);

   --  What state a zone is in, as a report describes it.
   --
   --  @enum Empty Nothing written
   --  @enum Implicitly_Open Being written without having been opened
   --  @enum Explicitly_Open Opened on purpose
   --  @enum Closed Written and set aside
   --  @enum Full No more may be written
   --  @enum Read_Only Readable and not writable
   --  @enum Offline Neither
   --  @enum Unknown A state this crate does not name
   type Zone_State is
     (Empty, Implicitly_Open, Explicitly_Open, Closed, Full, Read_Only,
      Offline, Unknown);

   --  One zone, as a report describes it.
   --
   --  @field Start The first block of the zone
   --  @field Capacity How many blocks it can hold, which may be fewer than
   --    the distance to the next zone
   --  @field Write_Pointer The block an append would land on
   --  @field State What may be done to it
   type Zone_Description is record
      Start         : U64;
      Capacity      : U64;
      Write_Pointer : U64;
      State         : Zone_State;
   end record;

   --  How large one zone descriptor is in a report.
   Zone_Descriptor_Bytes : constant := 64;

   --  How large the header before the first descriptor is.
   Zone_Report_Header_Bytes : constant := 64;

   --  Writes a command describing zones.
   --  @param Submission Where the namespace submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace
   --  @param First_Block Where to start describing
   --  @param Bytes How large the report buffer is
   --  @param Result_Address Where to deliver the report
   procedure Write_Zone_Report_Command
     (Submission     : Queue_Location;
      Slot           : Natural;
      Identifier     : U16;
      Namespace      : Namespace_Identifier;
      First_Block    : U64;
      Bytes          : Positive;
      Result_Address : U64)
     with Pre => Submission.Kind = Namespace_IO;

   --  Writes a command changing a zone's state.
   --  @param Submission Where the namespace submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace
   --  @param First_Block The first block of the zone to act on
   --  @param Action What to do to it
   --  @param All_Zones Whether to do it to every zone instead
   procedure Write_Zone_Action_Command
     (Submission  : Queue_Location;
      Slot        : Natural;
      Identifier  : U16;
      Namespace   : Namespace_Identifier;
      First_Block : U64;
      Action      : Zone_Action;
      All_Zones   : Boolean := False)
     with Pre => Submission.Kind = Namespace_IO;

   --  Writes a command appending to a zone.
   --  @param Submission Where the namespace submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace
   --  @param Zone_Start The first block of the zone to append to
   --  @param Blocks How many blocks to write, counted from one
   --  @param Address Where the data lives, as a device address
   procedure Write_Zone_Append_Command
     (Submission : Queue_Location;
      Slot       : Natural;
      Identifier : U16;
      Namespace  : Namespace_Identifier;
      Zone_Start : U64;
      Blocks     : Positive;
      Address    : U64)
     with Pre => Submission.Kind = Namespace_IO;

   --  Writes a command attaching a namespace to controllers, or detaching.
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace to attach or detach
   --  @param Attach True to attach, False to detach
   --  @param List_Address Where the controller list lives
   procedure Write_Namespace_Attachment_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Namespace    : Namespace_Identifier;
      Attach       : Boolean;
      List_Address : U64)
     with Pre => Submission.Kind = Admin;

   --  Fills in a controller list naming one controller.
   --  @param List Where the list lives
   --  @param Controller Which controller identifier to name
   procedure Write_Controller_List
     (List : System.Address; Controller : U16);

   --  How many zones a report says the namespace has.
   --  @param Report Address of the report
   --  @return The zone count
   function Reported_Zones (Report : System.Address) return U64;

   --  One zone out of a report.
   --  @param Report Address of the report
   --  @param Index Which descriptor, from zero
   --  @return What the report says about it
   function Reported_Zone
     (Report : System.Address; Index : Natural) return Zone_Description;

   --  Where a Zone Append actually landed, which the controller chooses
   --  and reports rather than the caller deciding.
   --  @param Queue Where the completion queue lives
   --  @param Slot Which entry to read
   --  @return The first block written
   function Appended_At
     (Queue : Queue_Location; Slot : Natural) return U64;

   --  An opcode no command set defines, for checking that a controller
   --  refuses what it does not implement rather than ignoring it.
   --  Which directive a Send or Receive concerns.
   type Directive_Kind is new U8;

   --  The directive every controller has, describing the others.
   Directive_Identify : constant Directive_Kind := 16#00#;

   --  The streams directive: writes carry a stream identifier and the
   --  controller keeps a stream's data together.
   Directive_Streams : constant Directive_Kind := 16#01#;

   --  Which operation of a directive to perform. The numbers are per
   --  directive and per direction, so the same value means different
   --  things in a Send and a Receive.
   type Directive_Operation is new U8;

   --  Which directive to switch on or off through the identify directive.
   --
   --  This goes in the twelfth command word and not, as it looks like it
   --  should, in the directive-specific field of the eleventh. The eleventh
   --  carries a value the directive itself defines — a stream identifier,
   --  say — and putting the enable there sets a stream number instead,
   --  which a controller either refuses or quietly obeys.
   --
   --  @field Kind Which directive to change
   --  @field Switched_On Whether to turn it on
   --  @field Meant Whether this word means anything at all
   type Enable_Directive is record
      Kind        : Directive_Kind := 0;
      Switched_On : Boolean := False;
      Meant       : Boolean := False;
   end record;

   --  Says the twelfth word carries nothing, for the operations that do
   --  not take one.
   No_Directive_Change : constant Enable_Directive :=
     (Kind => 0, Switched_On => False, Meant => False);

   --  Receive, identify directive: report what is supported and enabled.
   Directive_Return_Parameters : constant Directive_Operation := 16#01#;

   --  Send, identify directive: switch a directive on or off.
   Directive_Enable : constant Directive_Operation := 16#01#;

   --  Reads a directive's parameters into a buffer.
   --
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace, or none for the controller
   --  @param Result_Address Where to put the answer, as a device address
   --  @param Bytes How many bytes the buffer holds
   --  @param Directive Which directive to ask about
   --  @param Operation Which operation of it to perform
   --  @param Specific The directive-specific word, meaning nothing to most
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
     with Pre => Submission.Kind = Admin and then Bytes mod 4 = 0;

   --  Changes a directive's parameters.
   --
   --  Whether a buffer is needed depends on the directive: enabling one
   --  through the identify directive carries none, and Buffer_Address is
   --  then zero.
   --
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace, or none for the controller
   --  @param Buffer_Address Where the parameters live, or zero for none
   --  @param Bytes How many bytes the buffer holds, or zero for none
   --  @param Directive Which directive to change
   --  @param Operation Which operation of it to perform
   --  @param Specific The directive-specific word, which for streams is a
   --    stream identifier and for the identify directive means nothing
   --  @param Enable Which directive to switch on or off, and whether
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
     with Pre => Submission.Kind = Admin and then Bytes mod 4 = 0;

   --  Which directives a controller says it supports.
   --
   --  The first two bytes of an identify-directive Receive: a bitmap
   --  indexed by directive, then the same bitmap for those enabled.
   --
   --  @param Data Address of the returned parameters
   --  @param Directive Which directive to ask about
   --  @return True when the controller supports it
   function Directive_Supported
     (Data : System.Address; Directive : Directive_Kind) return Boolean;

   --  Whether a directive is currently switched on.
   --  @param Data Address of the returned parameters
   --  @param Directive Which directive to ask about
   --  @return True when it is enabled
   function Directive_Enabled
     (Data : System.Address; Directive : Directive_Kind) return Boolean;

   --  How a copy command's source ranges are laid out.
   --
   --  @enum Format_32_Byte The original layout
   --  @enum Format_40_Byte The same with a wider reference tag
   type Copy_Format is (Format_32_Byte, Format_40_Byte);

   --  How many bytes one source range descriptor occupies.
   --  @param Format Which layout
   --  @return The descriptor size
   function Copy_Range_Bytes (Format : Copy_Format) return Positive
     is (case Format is
            when Format_32_Byte => 32,
            when Format_40_Byte => 40);

   --  Which copy formats a controller says it supports.
   --
   --  Read from the Identify Controller structure, where a bit per format
   --  says whether a copy naming ranges in that layout will be accepted.
   --
   --  @param Data Address of the Identify Controller data
   --  @param Format Which layout
   --  @return True when the controller accepts that layout
   function Copy_Format_Supported
     (Data : System.Address; Format : Copy_Format) return Boolean;

   --  The largest number of source ranges one copy may name.
   --  @param Data Address of the Identify Namespace data
   --  @return The limit, or zero when the namespace states none
   function Maximum_Copy_Sources (Data : System.Address) return Natural;

   --  Fills in one entry of a copy command's source range list.
   --
   --  @param List Where the list lives
   --  @param Index Which entry, from zero
   --  @param First_Block The first block to copy from
   --  @param Blocks How many blocks to copy
   --  @param Format Which layout the list uses
   procedure Write_Copy_Source_Range
     (List        : System.Address;
      Index       : Natural;
      First_Block : U64;
      Blocks      : Positive;
      Format      : Copy_Format := Format_32_Byte)
     with Pre => Blocks <= 65_536;

   --  Copies blocks within a namespace.
   --
   --  @param Submission Where the namespace submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Namespace Which namespace
   --  @param List_Address Where the source range list lives, as a device
   --    address
   --  @param Sources How many ranges the list holds
   --  @param First_Block Where in the namespace to write the copy
   --  @param Format Which layout the list uses
   procedure Write_Copy_Command
     (Submission   : Queue_Location;
      Slot         : Natural;
      Identifier   : U16;
      Namespace    : Namespace_Identifier;
      List_Address : U64;
      Sources      : Positive;
      First_Block  : U64;
      Format       : Copy_Format := Format_32_Byte)
     with Pre => Submission.Kind = Namespace_IO and then Sources <= 256;

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
   --
   --  Note the number. Identifier zero is reserved, so the list starts at
   --  one and every feature sits one above where a reader counting from
   --  zero puts it. Getting this wrong on the first two is quiet: a Get of
   --  identifier zero is refused, but a Get of one when two was meant
   --  succeeds and answers about a different feature entirely.
   Feature_Arbitration : constant Feature_Identifier := 16#01#;

   --  Feature: the controller's power state.
   Feature_Power_Management : constant Feature_Identifier := 16#02#;

   --  Feature: which asynchronous events the controller may report.
   Feature_Async_Event_Configuration : constant Feature_Identifier := 16#0B#;

   --  Which of a feature's several values a Get should return.
   --
   --  A feature has a current value, a default the controller was built
   --  with, a saved value that survives a reset, and a description of which
   --  of those it supports at all. A driver that only ever reads the
   --  current value cannot tell a controller that ignored a Set from one
   --  that accepted it and reset.
   --
   --  @enum Current What the feature is set to now
   --  @enum Default What it was before anything set it
   --  @enum Saved What it will be after the next reset
   --  @enum Capabilities Which of the above this feature supports
   type Feature_Selection is (Current, Default, Saved, Capabilities);

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
   --  Interrupts are off unless a vector is named. A completion queue with
   --  interrupts enabled makes the controller signal the given MSI-X vector
   --  when it posts a completion, which is what turns a polled driver into
   --  one that can sleep.
   --
   --  @param Queue_Number Which queue to create, from one
   --  @param Entries How many entries it holds
   --  @param Address Where it lives, as a device address
   --  @param Interrupt_Vector Which MSI-X vector to signal, if any
   procedure Write_Create_Completion_Queue_Command
     (Submission       : Queue_Location;
      Slot             : Natural;
      Identifier       : U16;
      Queue_Number     : Queue_Identifier;
      Entries          : Positive;
      Address          : U64;
      Interrupt_Vector : Interrupt_Selection := No_Interrupt)
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
   --  page after it. Anything larger needs a page list, which
   --  Describe_Transfer below builds and this parameter then carries.
   --
   --  @param Submission Where the I/O submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Opcode Read or write
   --  @param Namespace Which namespace
   --  @param First_Block The first logical block
   --  @param Blocks How many blocks, counted from one
   --  @param Address Where the data lives, as a device address
   --  @param Continuation The second data pointer: unused for a transfer
   --    inside one page, the next page for one inside two, and a page list
   --    beyond that
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
     with Pre => Submission.Kind = Namespace_IO;

   ---------------------------------------------------------------------
   --  Describing a buffer larger than a page
   ---------------------------------------------------------------------

   --  The two data pointers a command carries.
   --
   --  NVMe has no scatter-gather list in its base form; it has two
   --  pointers and a rule that changes what the second one means depending
   --  on how much is being transferred. That rule is the reason a driver
   --  that works for a single block can fail for sixteen: the first pointer
   --  is the same in both cases and the second is not the same kind of
   --  thing.
   --
   --  @field First Where the transfer starts
   --  @field Second Unused, the next page, or a list of pages
   type Data_Pointers is record
      First  : U64 := 0;
      Second : U64 := 0;
   end record;

   --  How many pages one page-list page can name.
   --
   --  A list longer than this has to be chained, its last entry pointing at
   --  another list page. Nothing here does that: a transfer needing more
   --  than one list page is refused rather than described wrongly.
   --
   --  @param Page_Bytes The controller's page size
   --  @return How many entries fit
   function Page_List_Capacity (Page_Bytes : Positive) return Positive
     is (Page_Bytes / 8);

   --  Describes a transfer buffer to the controller, building a page list
   --  if the transfer needs one.
   --
   --  The three cases, which are the whole of the rule: a transfer ending
   --  inside the first page needs no second pointer at all; one ending
   --  inside the second page puts that page in the second pointer; anything
   --  longer puts a list of every page after the first there instead. A
   --  driver that only ever transfers one block never meets the second or
   --  third case and is not thereby correct.
   --
   --  The buffer must start on a page boundary. The specification allows an
   --  offset within the first page and nothing here needs one, so requiring
   --  alignment removes a case rather than hiding it.
   --
   --  @param Buffer Where the data lives, as a device address
   --  @param Bytes How many bytes the transfer covers
   --  @param Page_Bytes The controller's page size
   --  @param List_Host Where a page list may be built, in this process
   --  @param List_Device The same place as a device address
   --  @return The two pointers to put in the command
   --  @exception Device_Misbehaved The transfer needs more than one list
   --    page, or the buffer is not page-aligned
   function Describe_Transfer
     (Buffer      : U64;
      Bytes       : Positive;
      Page_Bytes  : Positive;
      List_Host   : System.Address;
      List_Device : U64) return Data_Pointers;

   --  The largest transfer the controller will accept, in bytes.
   --
   --  MDTS is held as a power of two multiplying the smallest page the
   --  controller supports, and zero means it states no limit at all rather
   --  than a limit of one page — the one place in this structure where zero
   --  does not mean zero.
   --
   --  @param Data Address of the Identify Controller data
   --  @param Capabilities The capabilities register, for the page size
   --  @return The limit in bytes, or zero when the controller states none
   function Maximum_Transfer_Bytes
     (Data : System.Address; Capabilities : U64) return Natural;

   --  Writes a command reading or changing a feature.
   --
   --  @param Submission Where the admin submission queue lives
   --  @param Slot Which entry to write, from zero
   --  @param Identifier The command identifier
   --  @param Opcode Get or set
   --  @param Feature Which feature
   --  @param Value The value to set, ignored when getting
   --  @param Namespace Which namespace, where the feature is per-namespace
   --  @param Selection Which value to read, ignored when setting
   --  @param Save Whether a set should survive the next reset
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
