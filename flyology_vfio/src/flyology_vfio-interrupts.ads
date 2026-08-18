private with Ada.Finalization;
with Interfaces;

--  Interrupt delivery, which VFIO does through eventfd.
--
--  A device cannot interrupt a userspace process directly, so VFIO turns an
--  interrupt into a write on an eventfd: the kernel's handler runs, writes
--  the descriptor, and whatever the process was doing with that descriptor
--  wakes. A driver therefore waits on descriptors, and can wait on them
--  alongside anything else it waits on.
--
--  The MSI-X shape is the one worth understanding. Enabling it takes a
--  request whose fixed head is followed by an array of descriptors, one per
--  vector, and the kernel validates the request's declared size against the
--  vector count. That variable tail is why the size field is not simply the
--  size of a record here; getting it wrong is rejected, which is the kernel
--  catching the mistake rather than the mistake going unnoticed.
--
--  What this package does not do: it does not mask, unmask, or acknowledge
--  anything at the device level. A device's own interrupt status and
--  acknowledgement registers are device knowledge, and belong to a driver.
package Flyology_VFIO.Interrupts is

   --  Which interrupt index of a device. For a PCI device, 0 is the legacy
   --  pin interrupt, 1 is MSI, and 2 is MSI-X.
   type IRQ_Index is range 0 .. 15;

   --  The legacy pin interrupt.
   Legacy_Pin : constant IRQ_Index := 0;

   --  Message signalled interrupts.
   MSI : constant IRQ_Index := 1;

   --  Extended message signalled interrupts, which most modern devices use.
   MSI_X : constant IRQ_Index := 2;

   --  What the kernel reports about one interrupt index.
   --
   --  @field Index Which index this describes
   --  @field Implemented Whether the device has this interrupt index at
   --    all. A PCI device reports five index slots whether or not it fills
   --    them, and a device with no MSI-X refuses to describe that slot
   --  @field Count How many vectors it offers; zero when the device does
   --    not implement this kind of interrupt at all
   --  @field Supports_Eventfd The index can signal an eventfd, which is the
   --    only delivery mechanism this crate uses
   --  @field Maskable Individual vectors can be masked through VFIO
   --  @field Automasked The kernel masks a vector when it fires, and it
   --    stays masked until unmasked; the legacy pin interrupt works this way
   type Interrupt_Details is record
      Index            : IRQ_Index;
      Implemented      : Boolean;
      Count            : Natural;
      Supports_Eventfd : Boolean;
      Maskable         : Boolean;
      Automasked       : Boolean;
   end record;

   --  Asks the kernel about one interrupt index.
   --
   --  An index the device does not implement is reported with Implemented
   --  false rather than raised, because iterating the indices is the
   --  ordinary way to discover which kinds of interrupt a device offers.
   --  Any other failure raises.
   --
   --  @param Device The device
   --  @param Index Which interrupt index
   --  @return What the kernel reports
   --  @exception Interrupt_Error The query failed for a reason other than
   --    the index not existing
   function Describe
     (Device : Device_FD; Index : IRQ_Index) return Interrupt_Details;

   --  An eventfd a device interrupt is delivered on.
   --
   --  Closes itself. Created non-blocking, so Take never waits; a driver
   --  that wants to block waits on the descriptor with whatever it already
   --  uses to wait on descriptors.
   --  Tagged in the visible part because the waiter below takes it
   --  class-wide, which the partial view has to admit to.
   type Event is tagged limited private;

   --  Creates an eventfd.
   --  @param Self The event to create
   --  @exception Interrupt_Error The eventfd could not be created
   procedure Open (Self : in out Event)
     with Pre => not Is_Open (Self), Post => Is_Open (Self);

   --  Whether the event holds an open eventfd.
   --  @param Self The event
   --  @return True between Open and Close
   function Is_Open (Self : Event) return Boolean;

   --  The underlying descriptor, for passing to Enable or to a poll loop.
   --  @param Self The event
   --  @return The eventfd descriptor
   function Descriptor (Self : Event) return Integer
     with Pre => Is_Open (Self);

   --  Takes the pending interrupt count, and resets it to zero.
   --
   --  Returns zero when nothing is pending. The count is the number of
   --  times the kernel signalled since the last Take, not the number of
   --  interrupts a device raised: several interrupts arriving before a Take
   --  are coalesced, which is why a driver polls its device's own status
   --  rather than assuming one wake means one event.
   --
   --  @param Self The event
   --  @return The count taken, or zero
   function Take (Self : Event) return Interfaces.Unsigned_64
     with Pre => Is_Open (Self);

   --  Closes the eventfd.
   --  @param Self The event to close
   procedure Close (Self : in out Event)
     with Post => not Is_Open (Self);

   ---------------------------------------------------------------------
   --  Waiting
   ---------------------------------------------------------------------

   --  A set of descriptors to wait on together.
   type Descriptor_Array is array (Positive range <>) of Integer;

   --  Something that can wait for a device to interrupt.
   --
   --  Declared rather than fixed, for the same reason Flyology_DMA declares
   --  an abstract Mapper: the crate cannot answer this without answering a
   --  question that belongs to the caller. What a program does while
   --  waiting for a device is bound up with how it does everything else —
   --  whether it has an event loop, whether it can afford a thread per
   --  device, whether it would rather spin and never sleep at all.
   --
   --  The three answers are all legitimate and none of them is the crate's
   --  to impose. A poll-mode driver never waits: it reads a completion
   --  queue in a loop and takes no interrupt on the data path at all, which
   --  costs a core and buys the lowest latency there is. A program with an
   --  event loop wants to suspend one task and let the others run. A
   --  program with neither wants to block and be done with it, which is
   --  what Blocking_Waiter below does.
   type Waiter is limited interface;

   --  Waits for one device to interrupt.
   --
   --  @param Self The waiter
   --  @param Signal The event the interrupt is delivered on
   --  @param Timeout How long to wait; negative means no limit
   --  @return True when the interrupt arrived, False on timeout
   --  @exception Interrupt_Error The wait itself failed
   --  The event is class-wide because a subprogram may not be a primitive
   --  of two tagged types, and both Waiter and Event are tagged. It also
   --  says the right thing: this dispatches on the waiter, never on the
   --  event.
   function Wait_For
     (Self    : in out Waiter;
      Signal  : Event'Class;
      Timeout : Duration) return Boolean is abstract;

   --  Waits for any of several devices, or several vectors of one.
   --
   --  Takes descriptors rather than events because an event is limited and
   --  cannot be put in an array, and because a caller waiting on several
   --  things usually holds them in several places.
   --
   --  @param Self The waiter
   --  @param Signals The descriptors to watch
   --  @param Timeout How long to wait; negative means no limit
   --  A descriptor reported ready stays ready until Take drains it. That
   --  is how an eventfd works and it is the single easiest way to write a
   --  driver that appears to hang: waiting again without draining returns
   --  the same descriptor, and since the lowest ready index wins, the
   --  first queue is reported forever and the others never. Take what you
   --  were given before you wait again.
   --
   --  @return The index of the descriptor that became ready, or zero on
   --    timeout. The lowest index wins when several are ready at once.
   --  @exception Interrupt_Error The wait itself failed
   function Wait_For_Any
     (Self    : in out Waiter;
      Signals : Descriptor_Array;
      Timeout : Duration) return Natural is abstract;

   --  A waiter that blocks the calling task, and nothing else.
   --
   --  Shipped so that a program with no event loop of its own has something
   --  that works. It is deliberately a duplicate: Flyology.IO.Wait already
   --  does this, better, for both lightweight and native tasks, and a
   --  program willing to depend on that runtime should use the waiter in
   --  flyology_vfio_runtime instead. This exists so that willingness is not
   --  a precondition for using this crate at all.
   type Blocking_Waiter is limited new Waiter with null record;

   overriding function Wait_For
     (Self    : in out Blocking_Waiter;
      Signal  : Event'Class;
      Timeout : Duration) return Boolean;

   overriding function Wait_For_Any
     (Self    : in out Blocking_Waiter;
      Signals : Descriptor_Array;
      Timeout : Duration) return Natural;

   --  No time limit, spelled as poll spells it.
   Wait_Forever : constant Duration := -1.0;

   --  The most vectors this package will enable at once.
   Maximum_Vectors : constant := 64;

   --  Descriptors to deliver each vector on, one per vector from zero.
   --
   --  A negative entry means that vector is not wanted, which is how a
   --  driver enables a subset.
   type Vector_Descriptors is array (Natural range <>) of Integer;

   --  Routes a device's interrupts to the given descriptors.
   --
   --  @param Device The device
   --  @param Index Which interrupt index to enable
   --  @param Vectors One descriptor per vector, starting at vector zero
   --  @exception Interrupt_Error The request was refused
   procedure Enable
     (Device  : Device_FD;
      Index   : IRQ_Index;
      Vectors : Vector_Descriptors)
     with Pre => Vectors'Length in 1 .. Maximum_Vectors;

   --  Re-arms an automasked interrupt.
   --
   --  This is not optional bookkeeping, and leaving it out is the quietest
   --  possible failure. A legacy pin interrupt is shared, so the kernel
   --  masks it the moment it fires and leaves it masked: it has no way to
   --  know when userspace has quieted the device, and an unmasked shared
   --  line would re-assert forever. A handler that acknowledges the device
   --  but never calls this receives exactly one interrupt and then nothing,
   --  with no error anywhere to say why.
   --
   --  Describe reports whether an index works this way. MSI and MSI-X do
   --  not, and calling this on them is harmless but pointless.
   --
   --  Acknowledge the device first, then call this. The other order
   --  re-arms the line while the device is still asserting it.
   --
   --  @param Device The device
   --  @param Index Which interrupt index to re-arm
   --  @exception Interrupt_Error The request was refused
   procedure Unmask (Device : Device_FD; Index : IRQ_Index);

   --  Masks an interrupt without disabling it.
   --  @param Device The device
   --  @param Index Which interrupt index to mask
   --  @exception Interrupt_Error The request was refused
   procedure Mask (Device : Device_FD; Index : IRQ_Index);

   --  Stops delivering a device's interrupts.
   --
   --  Do this before closing the eventfds, so the kernel is not left
   --  holding descriptors that have gone.
   --
   --  @param Device The device
   --  @param Index Which interrupt index to disable
   --  @exception Interrupt_Error The request was refused
   procedure Disable (Device : Device_FD; Index : IRQ_Index);

private

   type Event is limited new Ada.Finalization.Limited_Controlled with record
      Value : Integer := -1;
   end record;

   overriding procedure Finalize (Self : in out Event);

   function Is_Open (Self : Event) return Boolean is (Self.Value >= 0);
   function Descriptor (Self : Event) return Integer is (Self.Value);

end Flyology_VFIO.Interrupts;
