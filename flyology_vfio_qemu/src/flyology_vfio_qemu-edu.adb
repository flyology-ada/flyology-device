with Flyology_VFIO.Registers;
with Interfaces.C;

package body Flyology_VFIO_QEMU.Edu is

   package Reg renames Flyology_VFIO.Registers;

   --  Waiting between polls, rather than spinning, so that whatever is
   --  meant to make progress on the other side of the register window gets
   --  the chance to. Imported directly because this crate deliberately
   --  brings in no tasking runtime: a bring-up harness should link against
   --  as little as possible.
   procedure Wait_Microseconds (Count : Interfaces.C.unsigned)
     with Import, Convention => C, External_Name => "usleep";


   --------------------
   -- Identification --
   --------------------

   function Identification (BAR : Regions.Window) return U32 is
     (Reg.Read_32 (BAR, Identification_Register));

   ----------------------
   -- Liveness_Answer --
   ----------------------

   function Liveness_Answer (BAR : Regions.Window; Probe : U32) return U32 is
   begin
      Reg.Write_32 (BAR, Liveness_Register, Probe);
      return Reg.Read_32 (BAR, Liveness_Register);
   end Liveness_Answer;

   ------------
   -- Status --
   ------------

   function Status (BAR : Regions.Window) return U32 is
     (Reg.Read_32 (BAR, Status_Register));

   ------------------------------
   -- Set_Raise_On_Factorial --
   ------------------------------

   procedure Set_Raise_On_Factorial
     (BAR : Regions.Window; Enabled : Boolean)
   is
      Current : constant U32 := Reg.Read_32 (BAR, Status_Register);
   begin
      --  The status register is an ordinary read-write register here: no bit
      --  clears on being read and none clears on being written a one, so
      --  reading it and putting back a modified value is safe. That is not
      --  true of every status register, which is why it is worth saying.
      Reg.Write_32
        (BAR, Status_Register,
         (if Enabled
          then Current or Status_Raise_On_Factorial
          else Current and not Status_Raise_On_Factorial));
   end Set_Raise_On_Factorial;

   ----------------------
   -- Begin_Factorial --
   ----------------------

   procedure Begin_Factorial (BAR : Regions.Window; Argument : U32) is
   begin
      Reg.Write_32 (BAR, Factorial_Register, Argument);
   end Begin_Factorial;

   -----------------------
   -- Factorial_Result --
   -----------------------

   function Factorial_Result (BAR : Regions.Window) return U32 is
     (Reg.Read_32 (BAR, Factorial_Register));

   ---------------
   -- Factorial --
   ---------------

   function Factorial
     (BAR      : Regions.Window;
      Argument : U32;
      Attempts : Positive := 20_000;
      Pause_Microseconds : Natural := 100) return U32
   is
      Polls : Natural := 0;
   begin
      Begin_Factorial (BAR, Argument);

      --  The device sets the computing bit and clears it when done. The
      --  status read is an acquire load so that the result register read
      --  below cannot be hoisted above the flag that says it is valid —
      --  which is exactly the pattern every completion flag needs, and the
      --  reason Flyology_VFIO.Registers offers acquire reads at all.
      while (Reg.Read_Acquire_32 (BAR, Status_Register) and Status_Computing)
              /= 0
      loop
         Polls := Polls + 1;
         if Pause_Microseconds > 0 then
            Wait_Microseconds (Interfaces.C.unsigned (Pause_Microseconds));
         end if;
         if Polls >= Attempts then
            raise Device_Misbehaved with
              "the device was still computing the factorial of"
              & U32'Image (Argument) & " after" & Natural'Image (Attempts)
              & " polls. Either it never started, which means writes are"
              & " not reaching it, or it never finished.";
         end if;
      end loop;

      return Factorial_Result (BAR);
   end Factorial;

   -----------------------
   -- Interrupt_Status --
   -----------------------

   function Interrupt_Status (BAR : Regions.Window) return U32 is
     (Reg.Read_32 (BAR, Interrupt_Status_Register));

   ----------------------
   -- Raise_Interrupt --
   ----------------------

   procedure Raise_Interrupt (BAR : Regions.Window; Mask : U32) is
   begin
      --  A release store: everything the caller set up before asking for an
      --  interrupt is visible to the device before the request is.
      Reg.Write_Release_32 (BAR, Interrupt_Raise_Register, Mask);
   end Raise_Interrupt;

   ----------------------------
   -- Acknowledge_Interrupt --
   ----------------------------

   procedure Acknowledge_Interrupt (BAR : Regions.Window; Mask : U32) is
   begin
      Reg.Write_32 (BAR, Interrupt_Acknowledge_Register, Mask);
   end Acknowledge_Interrupt;

   -----------------------
   -- Transfer_Running --
   -----------------------

   function Transfer_Running (BAR : Regions.Window) return Boolean is
     ((Reg.Read_Acquire_64 (BAR, DMA_Command_Register) and DMA_Start) /= 0);

   --------------
   -- Transfer --
   --------------

   procedure Transfer
     (BAR         : Regions.Window;
      Source      : U64;
      Destination : U64;
      Count       : U64;
      Direction   : Transfer_Direction;
      Announce    : Boolean := False;
      Attempts    : Positive := 20_000;
      Pause_Microseconds : Natural := 100)
   is
      Command : U64 := DMA_Start;
      Polls   : Natural := 0;
   begin
      --  Refuse an address the device would silently truncate. Letting it
      --  through produces a transfer that completes, reports success, and
      --  moves nothing — or, without an IOMMU, moves the bytes somewhere
      --  nobody chose.
      declare
         type Endpoint_List is array (Positive range <>) of U64;
         Endpoints : constant Endpoint_List := [Source, Destination];
      begin
         for Endpoint of Endpoints loop
            if Endpoint > Maximum_DMA_Address then
               raise Device_Misbehaved with
                 "address" & U64'Image (Endpoint) & " is wider than the"
                 & " twenty-eight bits this device can put on the bus, and"
                 & " it would be masked to" & U64'Image
                   (Endpoint and Maximum_DMA_Address)
                 & " rather than refused. Choose an I/O virtual address"
                 & " below" & U64'Image (Maximum_DMA_Address + 1)
                 & ", or widen the device's dma_mask property when starting"
                 & " QEMU.";
            end if;
         end loop;
      end;

      if Direction = From_Device then
         Command := Command or DMA_From_Device;
      end if;
      if Announce then
         Command := Command or DMA_Raise_When_Done;
      end if;

      Reg.Write_64 (BAR, DMA_Source_Register, Source);
      Reg.Write_64 (BAR, DMA_Destination_Register, Destination);
      Reg.Write_64 (BAR, DMA_Count_Register, Count);

      --  Read the three back before starting. This device ignores writes to
      --  its transfer registers that are not exactly eight bytes wide, and
      --  it ignores all of them while a transfer is already running — in
      --  both cases silently. Checking here turns "the transfer did
      --  something unexpected" into "the device never received the
      --  request", which are very different problems.
      declare
         Kept_Source      : constant U64 :=
           Reg.Read_64 (BAR, DMA_Source_Register);
         Kept_Destination : constant U64 :=
           Reg.Read_64 (BAR, DMA_Destination_Register);
         Kept_Count       : constant U64 :=
           Reg.Read_64 (BAR, DMA_Count_Register);
      begin
         if Kept_Source /= Source
           or else Kept_Destination /= Destination
           or else Kept_Count /= Count
         then
            raise Device_Misbehaved with
              "the device did not keep the transfer it was given: asked for"
              & " source" & U64'Image (Source) & " destination"
              & U64'Image (Destination) & " count" & U64'Image (Count)
              & ", and it reports source" & U64'Image (Kept_Source)
              & " destination" & U64'Image (Kept_Destination) & " count"
              & U64'Image (Kept_Count) & ".";
         end if;
      end;

      --  The command register is the doorbell, and it is written with
      --  release ordering so the three registers above are visible to the
      --  device before it is told to act on them. On this emulated device
      --  the ordering is unobservable; on a real one it is the difference
      --  between working and working most of the time.
      Reg.Write_Release_64 (BAR, DMA_Command_Register, Command);

      while Transfer_Running (BAR) loop
         Polls := Polls + 1;
         if Pause_Microseconds > 0 then
            Wait_Microseconds (Interfaces.C.unsigned (Pause_Microseconds));
         end if;
         if Polls >= Attempts then
            --  Read the registers back rather than only reporting the
            --  timeout. Whether the device kept what it was told is the
            --  first thing worth knowing, and it distinguishes a device
            --  that never saw the request from one that saw it and could
            --  not carry it out.
            raise Device_Misbehaved with
              "a transfer of" & U64'Image (Count) & " bytes did not finish"
              & " after" & Natural'Image (Attempts) & " polls."
              & " The device now reports source"
              & U64'Image (Reg.Read_64 (BAR, DMA_Source_Register))
              & ", destination"
              & U64'Image (Reg.Read_64 (BAR, DMA_Destination_Register))
              & ", count"
              & U64'Image (Reg.Read_64 (BAR, DMA_Count_Register))
              & ", command"
              & U64'Image (Reg.Read_64 (BAR, DMA_Command_Register))
              & ". If those are not what was written, the register writes"
              & " are not reaching the device. If they are, the device"
              & " accepted the request and did not complete it: check that"
              & " bus mastering is enabled, which VFIO does not do for"
              & " you, and that the address is one the IOMMU can"
              & " translate.";
         end if;
      end loop;
   end Transfer;

end Flyology_VFIO_QEMU.Edu;
