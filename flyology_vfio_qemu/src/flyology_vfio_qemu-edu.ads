with Flyology_VFIO.Regions;
with Interfaces;
use type Interfaces.Unsigned_32;
use type Interfaces.Unsigned_64;

--  QEMU's educational PCI device.
--
--  edu exists in QEMU to be the smallest thing a driver can be written
--  against: one memory BAR, about ten registers, a DMA engine, and an
--  interrupt. It is the device this repository is brought up on, and it
--  earns that place for one reason above the others — its DMA engine
--  dereferences whatever address it is handed. That makes it able to prove
--  an I/O virtual address is correct, which no amount of testing against
--  the kernel's own refusals can do: an IOVA that is merely accepted by
--  VFIO tells you nothing, while an IOVA a device successfully reads
--  through tells you the IOMMU was programmed the way you meant.
--
--  Everything here is device knowledge, which is why it is in this crate
--  and not in flyology_vfio. The register offsets and their meanings come
--  from QEMU's own specification of the device.
--
--  The device has no silicon behind it. Nothing it demonstrates says
--  anything about bus timing, errata, or how a real device behaves under
--  load.
package Flyology_VFIO_QEMU.Edu is

   package Regions renames Flyology_VFIO.Regions;

   --  The PCI identity QEMU gives this device.
   Vendor_ID : constant U16 := 16#1234#;

   --  The device identifier, which is "edu" in the low bytes if you squint.
   Device_ID : constant U16 := 16#11E8#;

   --  The only region this device has, holding every register below.
   Register_BAR : constant Regions.Region_Index := 0;

   ---------------------------------------------------------------------
   --  Registers, at their offsets within the BAR
   ---------------------------------------------------------------------

   --  Identification, read only. The low sixteen bits spell the device and
   --  the high sixteen carry its version.
   Identification_Register : constant := 16#00#;

   --  Liveness check. Writing a value here makes the device return that
   --  value inverted, which is the cheapest possible proof that writes and
   --  reads are both reaching it.
   Liveness_Register : constant := 16#04#;

   --  Factorial computation. Writing N starts it; the result appears here
   --  when the status register says it has finished.
   Factorial_Register : constant := 16#08#;

   --  Status. Bit zero is set while a factorial is being computed, and bit
   --  seven asks the device to raise an interrupt when one finishes.
   Status_Register : constant := 16#20#;

   --  Which interrupts are currently asserted.
   Interrupt_Status_Register : constant := 16#24#;

   --  Writing a value here asserts the interrupts in it. Write only.
   Interrupt_Raise_Register : constant := 16#60#;

   --  Writing a value here clears the interrupts in it. Write only.
   Interrupt_Acknowledge_Register : constant := 16#64#;

   --  Where a transfer reads from. An address in the device's own space or
   --  an address on the bus, depending on the direction.
   DMA_Source_Register : constant := 16#80#;

   --  Where a transfer writes to.
   DMA_Destination_Register : constant := 16#88#;

   --  How many bytes to transfer.
   DMA_Count_Register : constant := 16#90#;

   --  The command register that starts a transfer.
   DMA_Command_Register : constant := 16#98#;

   --  Set in the status register while a factorial is being computed.
   Status_Computing : constant U32 := 16#01#;

   --  Set in the status register to ask for an interrupt when a factorial
   --  finishes.
   Status_Raise_On_Factorial : constant U32 := 16#80#;

   --  Set in the command register to begin a transfer. The device clears it
   --  when the transfer is done, which is how a caller knows.
   DMA_Start : constant U64 := 16#01#;

   --  Set in the command register to transfer from the device to memory;
   --  clear to transfer from memory to the device.
   DMA_From_Device : constant U64 := 16#02#;

   --  Set in the command register to raise an interrupt when the transfer
   --  finishes.
   DMA_Raise_When_Done : constant U64 := 16#04#;

   --  The interrupt the device raises when a transfer it was asked to
   --  announce has finished.
   DMA_Interrupt : constant U32 := 16#100#;

   --  Where the device's own buffer starts, as the DMA engine addresses it.
   --
   --  A transfer to the device names a destination in this range, and a
   --  transfer from the device names a source in it. Addresses outside it
   --  are rejected by the device.
   Device_Buffer_Base : constant U64 := 16#4_0000#;

   --  How large the device's own buffer is.
   Device_Buffer_Size : constant U64 := 4096;

   --  The widest bus address this device can emit.
   --
   --  edu carries a DMA mask, twenty-eight bits by default, and it does not
   --  reject an address wider than that: it silently masks it and issues
   --  the transfer against the result. An I/O virtual address of four
   --  gibibytes becomes zero, the IOMMU refuses the access because nothing
   --  is mapped there, and the transfer completes having moved nothing.
   --
   --  That is worth dwelling on, because it is the shape of the whole
   --  problem this repository exists for. Every layer behaved: the mapping
   --  was made, the registers were kept, the transfer ran, the device
   --  reported back exactly what it was given. The address was wrong only
   --  in a way the device chose not to mention. A real device with a
   --  narrow DMA mask does the same thing, and on a machine with no IOMMU
   --  to refuse the truncated address it would have written to whatever
   --  physical memory happened to be at the masked address instead.
   --
   --  A device's DMA width is therefore part of what constrains which
   --  IOVAs a driver may use, alongside the IOMMU's own input address size
   --  and the ranges the platform reserves. Transfer refuses an address
   --  that does not fit rather than letting it be masked.
   Maximum_DMA_Address : constant U64 := 2 ** 28 - 1;

   ---------------------------------------------------------------------
   --  Operations
   ---------------------------------------------------------------------

   --  Reads the identification register.
   --  @param BAR The device's mapped region
   --  @return The raw identification value
   function Identification (BAR : Regions.Window) return U32;

   --  Whether an identification value is one this device reports.
   --
   --  Only the low half is checked. The high half is a version, and pinning
   --  it would make the harness fail on a QEMU that had merely been
   --  updated.
   --
   --  @param Value An identification register reading
   --  @return True when the low half identifies this device
   function Is_Edu_Identification (Value : U32) return Boolean
     is ((Value and 16#FFFF#) = 16#00ED#);

   --  Writes a probe to the liveness register and reads the answer back.
   --
   --  The device answers with the probe inverted, so a caller checks
   --  Answer = not Probe. Anything else means writes or reads are not
   --  reaching the device, which is worth finding out before anything more
   --  elaborate is attempted.
   --
   --  @param BAR The device's mapped region
   --  @param Probe The value to send
   --  @return What the device returned
   function Liveness_Answer (BAR : Regions.Window; Probe : U32) return U32;

   --  Reads the status register.
   --  @param BAR The device's mapped region
   --  @return The status bits
   function Status (BAR : Regions.Window) return U32;

   --  Asks the device to raise an interrupt when a factorial finishes.
   --  @param BAR The device's mapped region
   --  @param Enabled Whether to raise one
   procedure Set_Raise_On_Factorial
     (BAR : Regions.Window; Enabled : Boolean);

   --  Starts a factorial computation and waits for it to finish.
   --
   --  The device computes with a deliberate delay, so this polls, and it
   --  waits between polls rather than spinning. That is not politeness: an
   --  emulated device is driven by its emulator's main loop, and a guest
   --  that never stops issuing register reads can keep that loop from
   --  reaching the work it was asked to do. The same is true, for
   --  different reasons, of a real device on a shared bus.
   --
   --  A caller that wants to do something else meanwhile can start it with
   --  Begin_Factorial and watch Status itself.
   --
   --  @param BAR The device's mapped region
   --  @param Argument The number to take the factorial of
   --  @param Attempts How many times to poll before giving up
   --  @param Pause_Microseconds How long to wait between polls
   --  @return The factorial
   --  @exception Device_Misbehaved The device did not finish in time
   function Factorial
     (BAR      : Regions.Window;
      Argument : U32;
      Attempts : Positive := 20_000;
      Pause_Microseconds : Natural := 100) return U32;

   --  Starts a factorial computation without waiting.
   --  @param BAR The device's mapped region
   --  @param Argument The number to take the factorial of
   procedure Begin_Factorial (BAR : Regions.Window; Argument : U32);

   --  Reads the factorial register.
   --  @param BAR The device's mapped region
   --  @return Whatever the register currently holds
   function Factorial_Result (BAR : Regions.Window) return U32;

   --  Which interrupts the device currently has asserted.
   --  @param BAR The device's mapped region
   --  @return The asserted interrupt bits
   function Interrupt_Status (BAR : Regions.Window) return U32;

   --  Asserts the given interrupts.
   --  @param BAR The device's mapped region
   --  @param Mask Which interrupts to assert
   procedure Raise_Interrupt (BAR : Regions.Window; Mask : U32);

   --  Clears the given interrupts.
   --  @param BAR The device's mapped region
   --  @param Mask Which interrupts to clear
   procedure Acknowledge_Interrupt (BAR : Regions.Window; Mask : U32);

   --  Which way a transfer goes.
   --  @enum To_Device From bus memory into the device's own buffer
   --  @enum From_Device From the device's own buffer out to bus memory
   type Transfer_Direction is (To_Device, From_Device);

   --  Starts a transfer and waits for the device to finish it.
   --
   --  Source and Destination are whole addresses as the device sees them:
   --  one of them is inside the device's buffer, and the other is an I/O
   --  virtual address that the IOMMU must have been programmed to
   --  translate. Handing it a host virtual address is the mistake this
   --  whole repository is arranged to prevent, and here it does not
   --  silently work: the IOMMU refuses the access.
   --
   --  Bus mastering must be enabled on the device, or the transfer will
   --  never start and this will time out.
   --
   --  @param BAR The device's mapped region
   --  @param Source Where to read from
   --  @param Destination Where to write to
   --  @param Count How many bytes
   --  @param Direction Which way the transfer goes
   --  @param Announce Whether the device should raise an interrupt at the end
   --  @param Attempts How many times to poll before giving up
   --  @param Pause_Microseconds How long to wait between polls
   --  @exception Device_Misbehaved The transfer did not finish in time, or
   --    an address is wider than the device can emit
   procedure Transfer
     (BAR         : Regions.Window;
      Source      : U64;
      Destination : U64;
      Count       : U64;
      Direction   : Transfer_Direction;
      Announce    : Boolean := False;
      Attempts    : Positive := 20_000;
      Pause_Microseconds : Natural := 100);

   --  Whether a transfer is still running.
   --  @param BAR The device's mapped region
   --  @return True while the command register's start bit is still set
   function Transfer_Running (BAR : Regions.Window) return Boolean;

end Flyology_VFIO_QEMU.Edu;
