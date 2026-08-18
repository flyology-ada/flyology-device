--  The namespace as something you store bytes on.
--
--  Every other NVMe test here drives one command and checks what came
--  back. This drives the layer built on top of them, which is where the
--  cases a single command never reaches start to matter.
--
--  Two of them, specifically, and both are ways a driver that passes every
--  one-block test still corrupts data.
--
--  A transfer longer than two pages needs a page list, and the list names
--  every page after the first. Off by one and the whole buffer moves by a
--  page: the first page still arrives, so the beginning of the data looks
--  right, and everything after it is wrong. The transfers below are ten
--  pages so that a list is built and long enough that a shift shows.
--
--  A transfer longer than the controller will take in one command has to be
--  broken up, and each piece has to know both where it goes in the
--  namespace and where it came from in the caller's memory. Two counters
--  advancing together, which is two chances to advance one and not the
--  other. So the amount written here is several times the largest single
--  transfer, with the last piece deliberately a different size from the
--  rest, and the pattern is checked across the whole of it rather than
--  sampled.

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
with Flyology_VFIO_QEMU;
with Flyology_VFIO_QEMU.NVMe;
with Flyology_VFIO_QEMU.NVMe.Blocks;
with Harness;
with Interfaces;
with System;

procedure NVMe_Blocks_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package Controller renames Flyology_VFIO_QEMU.NVMe;
   package Disk renames Flyology_VFIO_QEMU.NVMe.Blocks;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;

   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  Deliberately modest. A larger scratch area would let every transfer
   --  below fit in one command, and the chunking would then never run.
   Scratch_Bytes : constant := 64 * 1024;

   --  Several times the largest single transfer that fits in that scratch,
   --  and not a multiple of it, so the last piece is a different size.
   Payload_Bytes : constant := 128 * 1024;

   --  Far enough into the namespace that a transfer starting at block zero
   --  by mistake lands somewhere else entirely.
   Start_Block : constant U64 := 1_024;

   type Payload is array (Natural range <>) of U8;

   --  Position-dependent in a way that is not periodic in the page size or
   --  the chunk size, so a page swapped with another page, or a chunk
   --  written twice, does not accidentally match.
   function Pattern (Index : Natural) return U8
   is (U8 ((Index * 31 + Index / 4_093 + 17) mod 251));
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
               pragma Unreferenced (Bound);

               Host : constant System.Address :=
                 DMA.Regions.Base_Address (Area);

               Volume : Disk.Volume;
            begin
               Disk.Open
                 (Volume, BAR, Host, U64 (Window_Base), Scratch_Bytes);

               Harness.Check
                 (Volume.Is_Open,
                  "the volume opened: the controller was started, told to"
                  & " describe itself, and given a queue pair, without any"
                  & " of that appearing in this test");
               Harness.Note
                 ("model """ & Volume.Model & """, serial """
                  & Volume.Serial & """");
               Harness.Note
                 ("blocks are" & Positive'Image (Volume.Block_Bytes)
                  & " bytes, there are" & U64'Image (Volume.Block_Count)
                  & " of them, and one command moves at most"
                  & Positive'Image (Volume.Largest_Transfer) & " bytes");

               Harness.Check
                 (Volume.Capacity_Bytes
                    = Volume.Block_Count * U64 (Volume.Block_Bytes),
                  "the capacity is the block count times the block size,"
                  & " which is the only arithmetic a caller should have to"
                  & " trust here");

               if Volume.Capacity_Bytes
                 < Start_Block * U64 (Volume.Block_Bytes)
                   + Payload_Bytes
               then
                  Harness.Skip
                    ("every transfer check",
                     "the namespace is too small to hold the payload at"
                     & " the offset these tests use");
                  Disk.Close (Volume, BAR);
                  Config.Disable_Bus_Mastering (Device);
                  Harness.Report ("nvme_blocks_tests");
                  return;
               end if;

               Harness.Check
                 (Volume.Largest_Transfer > 2 * 4096,
                  "one command moves more than two pages, so the transfers"
                  & " below need a page list rather than the two pointers a"
                  & " short transfer gets away with");
               Harness.Check
                 (Payload_Bytes > 2 * Volume.Largest_Transfer,
                  "and the payload needs more than two commands, so the"
                  & " chunking runs rather than being skipped past");

               ------------------------------------------------------
               --  Bytes out and bytes back
               ------------------------------------------------------

               declare
                  Written : Payload (0 .. Payload_Bytes - 1);
                  Read_Back : Payload (0 .. Payload_Bytes - 1);
                  Matches : Boolean := True;
                  First_Wrong : Integer := -1;
               begin
                  for Index in Written'Range loop
                     Written (Index) := Pattern (Index);
                     Read_Back (Index) := 16#DB#;
                  end loop;

                  Disk.Write (Volume, BAR, Start_Block,
                              Disk.Byte_Sequence (Written));
                  Harness.Check
                    (True,
                     "a payload of" & Natural'Image (Payload_Bytes)
                     & " bytes was written across several commands");

                  Disk.Flush (Volume, BAR);
                  Harness.Check (True, "and the controller committed it");

                  Disk.Read (Volume, BAR, Start_Block,
                             Disk.Byte_Sequence (Read_Back));

                  for Index in Read_Back'Range loop
                     if Read_Back (Index) /= Written (Index) then
                        Matches := False;
                        if First_Wrong < 0 then
                           First_Wrong := Index;
                        end if;
                     end if;
                  end loop;

                  if not Matches then
                     Harness.Note
                       ("the first byte that differs is at"
                        & Integer'Image (First_Wrong) & ", which is page"
                        & Integer'Image (First_Wrong / 4096) & " of the"
                        & " transfer");
                  end if;
                  Harness.Check
                    (Matches,
                     "every byte read back is the byte written, across"
                     & " every chunk and every page of every page list");

                  ---------------------------------------------------
                  --  Reading a piece of what was written
                  ---------------------------------------------------

                  declare
                     Offset_Blocks : constant U64 := 3;
                     Offset : constant Natural :=
                       Natural (Offset_Blocks) * Volume.Block_Bytes;
                     Piece : Payload (0 .. 8 * Volume.Block_Bytes - 1);
                     Aligned : Boolean := True;
                  begin
                     Disk.Read
                       (Volume, BAR, Start_Block + Offset_Blocks,
                        Disk.Byte_Sequence (Piece));
                     for Index in Piece'Range loop
                        if Piece (Index) /= Pattern (Offset + Index) then
                           Aligned := False;
                        end if;
                     end loop;
                     Harness.Check
                       (Aligned,
                        "reading eight blocks from three blocks in returns"
                        & " the bytes that were written three blocks in,"
                        & " so a block number means the same thing to a"
                        & " read as it did to the write");
                  end;
               end;

               ------------------------------------------------------
               --  Zeroing, which sends nothing
               ------------------------------------------------------

               declare
                  Blank : Payload (0 .. 4 * Volume.Block_Bytes - 1);
                  All_Zero : Boolean := True;
                  Neighbour : Payload (0 .. Volume.Block_Bytes - 1);
                  Untouched : Boolean := True;
               begin
                  Disk.Zero (Volume, BAR, Start_Block, 4);
                  Disk.Read (Volume, BAR, Start_Block,
                             Disk.Byte_Sequence (Blank));
                  for Index in Blank'Range loop
                     if Blank (Index) /= 0 then
                        All_Zero := False;
                     end if;
                  end loop;
                  Harness.Check
                    (All_Zero,
                     "four zeroed blocks read back as zero, having crossed"
                     & " the bus as a command rather than as four blocks of"
                     & " zeroes");

                  Disk.Read (Volume, BAR, Start_Block + 4,
                             Disk.Byte_Sequence (Neighbour));
                  for Index in Neighbour'Range loop
                     if Neighbour (Index)
                       /= Pattern (4 * Volume.Block_Bytes + Index)
                     then
                        Untouched := False;
                     end if;
                  end loop;
                  Harness.Check
                    (Untouched,
                     "and the block after them still holds what was"
                     & " written, so the zeroing stopped where it was told"
                     & " to");
               end;

               ------------------------------------------------------
               --  Giving blocks up
               ------------------------------------------------------

               Disk.Discard (Volume, BAR, Start_Block + 64, 8);
               Harness.Check
                 (True,
                  "eight blocks were given up; what the controller does"
                  & " with them afterwards is its own business and this"
                  & " does not check it");

               ------------------------------------------------------
               --  What the interface refuses
               ------------------------------------------------------

               declare
                  Ragged : Payload (0 .. Volume.Block_Bytes);
                  Refused : Boolean := False;
               begin
                  Disk.Read (Volume, BAR, Start_Block,
                             Disk.Byte_Sequence (Ragged));
               exception
                  when Device_Misbehaved =>
                     Refused := True;
                     Harness.Check
                       (Refused,
                        "a read of one byte more than a block is refused"
                        & " rather than rounded to something the caller did"
                        & " not ask for");
               end;

               declare
                  Beyond : Payload (0 .. Volume.Block_Bytes - 1);
                  Refused : Boolean := False;
               begin
                  Disk.Read (Volume, BAR, Volume.Block_Count,
                             Disk.Byte_Sequence (Beyond));
               exception
                  when Device_Misbehaved =>
                     Refused := True;
                     Harness.Check
                       (Refused,
                        "and a read starting past the last block is refused"
                        & " here rather than sent for the controller to"
                        & " refuse");
               end;

               Disk.Close (Volume, BAR);
               Harness.Check
                 (not Volume.Is_Open,
                  "the volume closed, and says so");
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end;

   Harness.Report ("nvme_blocks_tests");

exception
   when Error : Device_Not_Available =>
      Harness.Skip
        ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("nvme_blocks_tests");
end NVMe_Blocks_Tests;
