--  Copying without the host seeing the data, and directives.
--
--  Copy is the most demanding command in the set for the layers below this
--  one. Every other command has the controller reach one host address, or
--  two if a page list is involved, and hand back something the caller can
--  look at. Copy has it read a descriptor list from one device address,
--  read the blocks that list names, and write them somewhere else, with
--  nothing crossing back into host memory at all. Three separately
--  programmed addresses have to be right and no reply says whether they
--  were. The only way to find out is to read the destination afterwards
--  and see whether the bytes arrived, which is what this does.
--
--  Two source ranges rather than one, deliberately. A single range would
--  pass whatever stride the descriptor list was written at, so it would not
--  distinguish a correct layout from one that happens to start in the right
--  place.
--
--  Directives are the other half. A directive is a side channel for telling
--  the controller something about data it has not been given yet, and the
--  identify directive — the one that describes the others — is the only
--  part a controller must have. Whether anything can be switched on through
--  it is a property of the emulated device, and this reports what it finds
--  rather than insisting.

with Ada.Exceptions;
with Flyology_DMA;
with Flyology_DMA.Mappers;
with Flyology_DMA.Regions;
with Flyology_VFIO;
with Flyology_VFIO.Config_Space;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Devices;
with Flyology_VFIO.DMA_Mapper;
with Flyology_VFIO.Groups;
with Flyology_VFIO.Regions;
with Flyology_VFIO.Registers;
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.NVMe;
with Harness;
with System;
with Interfaces;

procedure NVMe_Copy_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package Controller renames Flyology_VFIO_QEMU.NVMe;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package Reg renames Flyology_VFIO.Registers;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   Admin_Sub_Offset  : constant DMA.Byte_Count := 0;
   Admin_Comp_Offset : constant DMA.Byte_Count := 4096;
   IO_Sub_Offset     : constant DMA.Byte_Count := 8192;
   IO_Comp_Offset    : constant DMA.Byte_Count := 12288;
   Identify_Offset   : constant DMA.Byte_Count := 16384;
   Source_Offset     : constant DMA.Byte_Count := 20480;
   Readback_Offset   : constant DMA.Byte_Count := 24576;
   List_Offset       : constant DMA.Byte_Count := 28672;
   Directive_Offset  : constant DMA.Byte_Count := 32768;
   Scratch_Bytes     : constant := 36864;

   Queue_Entries : constant Positive := 16;
   IO_Queue      : constant Controller.Queue_Identifier := 1;

   --  The ordinary namespace. Copy on a zoned one would have to respect
   --  write pointers, which is a different test.
   Namespace : constant Controller.Namespace_Identifier := 1;

   --  Where the two sources sit and where the copy lands. Far enough apart
   --  that a stride mistake cannot land on the right blocks by luck.
   First_Source  : constant U64 := 0;
   Second_Source : constant U64 := 64;
   Destination   : constant U64 := 512;
begin
   declare
      Where : constant String := Find (Controller.Vendor_ID,
                                       Controller.Device_ID);
      Container : Container_FD;
      Group     : Group_FD;
      Device    : Device_FD;
   begin
      Harness.Note ("device at " & Where);

      Containers.Open (Container);
      Groups.Open (Group, Groups.Group_Of (Where));
      Groups.Attach (Group, Container);
      Containers.Set_IOMMU (Container);
      Devices.Open (Device, Group, Container, Where);
      Config.Enable_Bus_Mastering (Device);

      declare
         BAR : Device_Regions.Window;
      begin
         Device_Regions.Map (BAR, Device, Controller.Register_BAR);

         declare
            Capabilities : constant U64 :=
              Reg.Read_64 (BAR, Controller.Capabilities_Register);
            Stride : constant Positive :=
              Controller.Doorbell_Stride (Capabilities);
            Backend : aliased DMA_Mapper.Container_Mapper;
            Area : constant DMA.Regions.Region :=
              DMA.Regions.Create (2 * 1024 * 1024, DMA.Regular_Pages);
         begin
            DMA_Mapper.Bind (Backend, Container);

            declare
               Bound : constant DMA.Mappers.Mapping :=
                 DMA.Mappers.Map_Region
                   (Backend'Access, Area, Window_Base,
                    DMA.Mappers.Device_Reads_And_Writes);
               --  Both addresses come from the mapping rather than being
               --  recomputed beside it. It knows its own extent, so an
               --  offset that would put a structure past the end of the
               --  region is refused here instead of becoming an address
               --  the device faults on.
               function At_Host
                 (Offset : DMA.Byte_Count; Extent : DMA.Byte_Count := 1)
                  return System.Address
               is (Bound.Host_At (Offset, Extent));

               function At_Device
                 (Offset : DMA.Byte_Count; Extent : DMA.Byte_Count := 1)
                  return Device_Address
               is (Bound.Device_At (Offset, Extent));

               Host : constant System.Address := Bound.Host_At (0);

               Admin_Sub : constant Controller.Queue_Location :=
                 (Kind    => Controller.Admin,
                  Host    => At_Host (Admin_Sub_Offset),
                  Device  => At_Device (Admin_Sub_Offset),
                  Entries => Queue_Entries);
               Admin_Comp : constant Controller.Queue_Location :=
                 (Kind    => Controller.Admin,
                  Host    => At_Host (Admin_Comp_Offset),
                  Device  => At_Device (Admin_Comp_Offset),
                  Entries => Queue_Entries);
               IO_Sub : constant Controller.Queue_Location :=
                 (Kind    => Controller.Namespace_IO,
                  Host    => At_Host (IO_Sub_Offset),
                  Device  => At_Device (IO_Sub_Offset),
                  Entries => Queue_Entries);
               IO_Comp : constant Controller.Queue_Location :=
                 (Kind    => Controller.Namespace_IO,
                  Host    => At_Host (IO_Comp_Offset),
                  Device  => At_Device (IO_Comp_Offset),
                  Entries => Queue_Entries);

               Everything : array (1 .. Scratch_Bytes) of U8
                 with Import, Volatile, Address => Host;
               Source_Bytes : array (0 .. 4095) of U8
                 with Import, Volatile, Address => At_Host (Source_Offset);
               Readback_Bytes : array (0 .. 4095) of U8
                 with Import, Volatile, Address => At_Host (Readback_Offset);

               Admin_Slot : Natural := 0;
               IO_Slot    : Natural := 0;
               Next_ID    : U16 := 1;

               function Run_Admin return Controller.Completion;
               function Run_IO return Controller.Completion;

               function Run_Admin return Controller.Completion is
                  Answer : Controller.Completion;
               begin
                  Controller.Ring_Submission_Doorbell
                    (BAR, Stride, Controller.Admin_Queue,
                     (Admin_Slot + 1) mod Queue_Entries);
                  Answer := Controller.Await_Completion
                    (Admin_Comp, Admin_Slot, True);
                  Controller.Ring_Completion_Doorbell
                    (BAR, Stride, Controller.Admin_Queue,
                     (Admin_Slot + 1) mod Queue_Entries);
                  Admin_Slot := Admin_Slot + 1;
                  Next_ID := Next_ID + 1;
                  return Answer;
               end Run_Admin;

               function Run_IO return Controller.Completion is
                  Answer : Controller.Completion;
               begin
                  Controller.Ring_Submission_Doorbell
                    (BAR, Stride, IO_Queue,
                     (IO_Slot + 1) mod Queue_Entries);
                  Answer := Controller.Await_Completion
                    (IO_Comp, IO_Slot, True);
                  Controller.Ring_Completion_Doorbell
                    (BAR, Stride, IO_Queue,
                     (IO_Slot + 1) mod Queue_Entries);
                  IO_Slot := IO_Slot + 1;
                  Next_ID := Next_ID + 1;
                  return Answer;
               end Run_IO;

               --  Two patterns that no plausible mistake produces: a
               --  destination left blank, filled with one source twice, or
               --  filled with the two in the wrong order all read
               --  differently from the expected bytes.
               function Pattern_A (Index : Natural) return U8
               is (U8 ((Index * 13 + 7) mod 251) xor 16#5A#);

               function Pattern_B (Index : Natural) return U8
               is (U8 ((Index * 29 + 3) mod 241) xor 16#A5#);
            begin
               Everything := (others => 0);
               Controller.Disable (BAR);
               Controller.Enable (BAR, Admin_Sub, Admin_Comp);

               Controller.Write_Identify_Command
                 (Admin_Sub, Admin_Slot, Next_ID, At_Device (Identify_Offset));
               Harness.Check_Equal
                 (U32 (Run_Admin.Status), 0, "the controller identified itself");

               declare
                  Thirty_Two : constant Boolean :=
                    Controller.Copy_Format_Supported
                      (At_Host (Identify_Offset), Controller.Format_32_Byte);
                  Forty : constant Boolean :=
                    Controller.Copy_Format_Supported
                      (At_Host (Identify_Offset), Controller.Format_40_Byte);
               begin
                  Harness.Note
                    ("copy descriptor formats: thirty-two byte "
                     & Boolean'Image (Thirty_Two)
                     & ", forty byte " & Boolean'Image (Forty));
                  Harness.Check
                    (Thirty_Two or else Forty,
                     "the controller supports at least one copy descriptor"
                     & " layout, which is what makes the command usable at"
                     & " all rather than merely present");
               end;

               Controller.Write_Identify_Namespace_Command
                 (Admin_Sub, Admin_Slot, Next_ID, Namespace,
                  At_Device (Identify_Offset));
               Harness.Check_Equal
                 (U32 (Run_Admin.Status), 0, "and the namespace");

               declare
                  Block_Bytes : constant Positive :=
                    Controller.Namespace_Block_Bytes
                      (At_Host (Identify_Offset));
                  Sources_Allowed : constant Natural :=
                    Controller.Maximum_Copy_Sources
                      (At_Host (Identify_Offset));
                  Blocks_Each : constant Positive :=
                    Positive'Max (1, 2048 / Block_Bytes);
                  Half : constant Natural := Blocks_Each * Block_Bytes;
               begin
                  Harness.Note
                    ("blocks are" & Positive'Image (Block_Bytes)
                     & " bytes and one copy may name up to"
                     & Natural'Image (Sources_Allowed) & " ranges;"
                     & " copying" & Positive'Image (Blocks_Each)
                     & " blocks from each of two places");
                  Harness.Check
                    (Sources_Allowed >= 2,
                     "the namespace allows a copy to name two source"
                     & " ranges, which is the case that distinguishes a"
                     & " correct descriptor stride from a lucky one");

                  Controller.Write_Create_Completion_Queue_Command
                    (Admin_Sub, Admin_Slot, Next_ID, IO_Queue, Queue_Entries,
                     IO_Comp.Device);
                  Harness.Check_Equal
                    (U32 (Run_Admin.Status), 0, "a queue pair was created");
                  Controller.Write_Create_Submission_Queue_Command
                    (Admin_Sub, Admin_Slot, Next_ID, IO_Queue, IO_Queue,
                     Queue_Entries, IO_Sub.Device);
                  Harness.Check_Equal
                    (U32 (Run_Admin.Status), 0, "both of it");

                  ---------------------------------------------------
                  --  Putting something in both places
                  ---------------------------------------------------

                  for Index in 0 .. Half - 1 loop
                     Source_Bytes (Index) := Pattern_A (Index);
                  end loop;
                  Controller.Write_Block_Command
                    (IO_Sub, IO_Slot, Next_ID, Controller.Opcode_Write,
                     Namespace, First_Source, Blocks_Each,
                     At_Device (Source_Offset));
                  Harness.Check_Equal
                    (U32 (Run_IO.Status), 0, "the first source was written");

                  for Index in 0 .. Half - 1 loop
                     Source_Bytes (Index) := Pattern_B (Index);
                  end loop;
                  Controller.Write_Block_Command
                    (IO_Sub, IO_Slot, Next_ID, Controller.Opcode_Write,
                     Namespace, Second_Source, Blocks_Each,
                     At_Device (Source_Offset));
                  Harness.Check_Equal
                    (U32 (Run_IO.Status), 0, "and the second");

                  ---------------------------------------------------
                  --  The copy itself
                  ---------------------------------------------------

                  Controller.Write_Copy_Source_Range
                    (At_Host (List_Offset), 0, First_Source, Blocks_Each);
                  Controller.Write_Copy_Source_Range
                    (At_Host (List_Offset), 1, Second_Source, Blocks_Each);
                  Controller.Write_Copy_Command
                    (IO_Sub, IO_Slot, Next_ID, Namespace,
                     At_Device (List_Offset), 2, Destination);

                  declare
                     Answer : constant Controller.Completion := Run_IO;
                  begin
                     if Answer.Status /= 0 then
                        --  A failure, not a skip. The namespace has already
                        --  said it accepts two ranges, so a refusal here is
                        --  the copy path breaking — and skipping would let
                        --  this file's whole subject regress to
                        --  always-refuse while the suite stayed green.
                        Harness.Check
                          (False,
                           "the controller refused a two-range copy with"
                           & " status 0x" & Hex_16 (Answer.Status)
                           & " after saying it accepts two");
                     else
                        Harness.Check
                          (True,
                           "the controller accepted a copy naming two"
                           & " source ranges in a list it had to fetch"
                           & " from memory itself");

                        for Index in 0 .. 4095 loop
                           Readback_Bytes (Index) := 16#EE#;
                        end loop;
                        Controller.Write_Block_Command
                          (IO_Sub, IO_Slot, Next_ID, Controller.Opcode_Read,
                           Namespace, Destination, 2 * Blocks_Each,
                           At_Device (Readback_Offset));
                        Harness.Check_Equal
                          (U32 (Run_IO.Status), 0,
                           "the destination read back");

                        declare
                           First_Matches  : Boolean := True;
                           Second_Matches : Boolean := True;
                        begin
                           for Index in 0 .. Half - 1 loop
                              if Readback_Bytes (Index) /= Pattern_A (Index)
                              then
                                 First_Matches := False;
                              end if;
                              if Readback_Bytes (Half + Index)
                                /= Pattern_B (Index)
                              then
                                 Second_Matches := False;
                              end if;
                           end loop;

                           Harness.Check
                             (First_Matches,
                              "the first source's bytes are at the start of"
                              & " the destination, so the controller read a"
                              & " descriptor from an address this code"
                              & " programmed and followed what it said");
                           Harness.Check
                             (Second_Matches,
                              "and the second source's bytes follow them,"
                              & " which is true only if the second"
                              & " descriptor was read at the right stride"
                              & " and its blocks written after the first");
                        end;
                     end if;
                  end;

                  ---------------------------------------------------
                  --  What a copy is not allowed to do
                  ---------------------------------------------------

                  declare
                     Blocks : constant U64 :=
                       Controller.Namespace_Blocks
                         (At_Host (Identify_Offset));
                  begin
                     Controller.Write_Copy_Source_Range
                       (At_Host (List_Offset), 0, Blocks, Blocks_Each);
                     Controller.Write_Copy_Command
                       (IO_Sub, IO_Slot, Next_ID, Namespace,
                        At_Device (List_Offset), 1, Destination);
                     declare
                        Answer : constant Controller.Completion := Run_IO;
                     begin
                        Harness.Check
                          (Answer.Status /= 0,
                           "a copy whose source starts past the end of the"
                           & " namespace is refused rather than quietly"
                           & " reading whatever is there");
                        Harness.Note
                          ("it answered 0x" & Hex_16 (Answer.Status));
                     end;
                  end;

                  if Sources_Allowed < 256 then
                     Controller.Write_Copy_Command
                       (IO_Sub, IO_Slot, Next_ID, Namespace,
                        At_Device (List_Offset), Sources_Allowed + 1,
                        Destination);
                     declare
                        Answer : constant Controller.Completion := Run_IO;
                     begin
                        Harness.Check
                          (Answer.Status /= 0,
                           "and a copy naming more ranges than the namespace"
                           & " said it would accept is refused, so the limit"
                           & " it reports is one it keeps");
                     end;
                  else
                     Harness.Skip
                       ("the range-count limit",
                        "this namespace accepts as many ranges as the"
                        & " command can encode, so there is no limit to"
                        & " exceed");
                  end if;
               end;

               ------------------------------------------------------
               --  Directives
               ------------------------------------------------------

               Controller.Write_Directive_Receive_Command
                 (Admin_Sub, Admin_Slot, Next_ID, Namespace,
                  At_Device (Directive_Offset), 4096);
               declare
                  Answer : constant Controller.Completion := Run_Admin;
               begin
                  if Answer.Status /= 0 then
                     Harness.Skip
                       ("every directive check",
                        "the controller refused to describe its directives,"
                        & " answering 0x" & Hex_16 (Answer.Status));
                  else
                     Harness.Check
                       (Controller.Directive_Supported
                          (At_Host (Directive_Offset),
                           Controller.Directive_Identify),
                        "the controller supports the identify directive,"
                        & " which is the one that describes the others and"
                        & " the one a controller answering at all must have");

                     declare
                        Streams_First : constant Boolean :=
                          Controller.Directive_Supported
                            (At_Host (Directive_Offset),
                             Controller.Directive_Streams);
                     begin
                        Harness.Note
                          ("the streams directive is "
                           & (if Streams_First then "supported"
                              else "not supported")
                           & " and "
                           & (if Controller.Directive_Enabled
                                   (At_Host (Directive_Offset),
                                    Controller.Directive_Streams)
                              then "already enabled" else "switched off"));

                        if Streams_First then
                           --  Switching a directive on goes through the
                           --  identify directive, and the word that says
                           --  which and whether is the twelfth — not the
                           --  directive-specific field of the eleventh,
                           --  where it looks like it belongs and where a
                           --  controller reads it as a stream number.
                           Controller.Write_Directive_Send_Command
                             (Admin_Sub, Admin_Slot, Next_ID, Namespace,
                              Enable =>
                                (Kind        => Controller.Directive_Streams,
                                 Switched_On => True,
                                 Meant       => True));
                           declare
                              Sent : constant Controller.Completion :=
                                Run_Admin;
                           begin
                              if Sent.Status /= 0 then
                                 Harness.Skip
                                   ("enabling a directive",
                                    "the controller refused with status 0x"
                                    & Hex_16 (Sent.Status));
                              else
                                 Controller.Write_Directive_Receive_Command
                                   (Admin_Sub, Admin_Slot, Next_ID, Namespace,
                                    At_Device (Directive_Offset), 4096);
                                 Harness.Check_Equal
                                   (U32 (Run_Admin.Status), 0,
                                    "the directives were described again");
                                 Harness.Check
                                   (Controller.Directive_Enabled
                                      (At_Host (Directive_Offset),
                                       Controller.Directive_Streams),
                                    "and now report the streams directive"
                                    & " enabled, so the send changed"
                                    & " something rather than being"
                                    & " accepted and discarded");
                              end if;
                           end;
                        else
                           Harness.Skip
                             ("enabling a directive",
                              "this controller supports only the identify"
                              & " directive, which cannot be switched off"
                              & " and so cannot be switched on");
                        end if;
                     end;
                  end if;
               end;

               Controller.Disable (BAR);
            exception
               --  Also on the way out through an exception, not only on
               --  the way out through the end. A device is not finished
               --  with a ring because the program that programmed it has
               --  stopped caring: the mapping goes away as this block
               --  unwinds, and anything still writing there writes to an
               --  address the IOMMU no longer translates. The fault storm
               --  that follows buries whatever raised in the first place.
               when others =>
                  begin
                     Controller.Disable (BAR);
                  exception
                     when others => null;
                  end;
                  raise;
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   Harness.Report ("nvme_copy_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("nvme_copy_tests");
end NVMe_Copy_Tests;
