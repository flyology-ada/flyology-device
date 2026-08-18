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
   type Event is limited private;

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
