--  A filesystem and a driver looking at the same disk.
--
--  Every NVMe test here checks the controller against itself: write blocks,
--  read them back, compare. That establishes the command layer and stops
--  short of the thing a block device is for. Nothing has ever put a
--  filesystem on the medium and asked whether the two views agree.
--
--  So this runs in three turns, and each turn owns the namespace outright —
--  which is not a simplification but the only correct way to share a disk
--  between two drivers.
--
--  Which filesystem it is does not matter and is deliberately not relied
--  on: the driver finds the payload by reading the medium and looking for
--  it, not by parsing anything. So the one the base guest image can already
--  make is the one used, because a harness that needs a package installed
--  first works on the machine it was written on and nowhere else.
--
--  Writing. The kernel has the namespace, a filesystem is mounted on it,
--  and a file is written through Flyology's file interface with a payload
--  chosen to appear nowhere else. Then it is unmounted, which is what makes
--  the bytes reach the medium rather than a cache.
--
--  Finding. The namespace belongs to this driver now. It reads the medium a
--  chunk at a time looking for that payload, and rewrites it in place with
--  a different one of the same length. No filesystem structure is parsed:
--  the payload is found by looking, which is what makes this test say
--  nothing about FAT and everything about whether the blocks are the same
--  blocks.
--
--  Reading. The kernel has it back, the filesystem is mounted again, and
--  the file is read through the same interface. What comes out is what the
--  driver wrote.
--
--  A failure in the last turn is the interesting one. It means the raw
--  driver and the filesystem disagree about where a byte lives, which is
--  the class of mistake that a test comparing a driver to itself cannot
--  see.

with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Flyology.IO.Files;
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

procedure NVMe_File_Tests is
   use Flyology_VFIO;
   use Flyology_VFIO_QEMU;

   package Config renames Flyology_VFIO.Config_Space;
   package Controller renames Flyology_VFIO_QEMU.NVMe;
   package Disk renames Flyology_VFIO_QEMU.NVMe.Blocks;
   package DMA renames Flyology_DMA;
   package Device_Regions renames Flyology_VFIO.Regions;
   package Files renames Flyology.IO.Files;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type DMA.Byte_Count;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;

   Window_Base : constant DMA.IOVA_Address := 16#0400_0000#;

   --  The namespace nothing else writes to, so that a filesystem on it
   --  survives every other suite in the run.
   Namespace : constant Controller.Namespace_Identifier := 4;

   Where_Mounted : constant String := "/mnt/nvme";
   File_Path     : constant String := Where_Mounted & "/witness.dat";

   --  Long enough not to occur by chance on a freshly made filesystem, and
   --  the same length as what replaces it so that finding one and writing
   --  the other needs no bookkeeping.
   --
   --  Both end in a token the harness varies per run, and that is not
   --  decoration. The file is rewritten each time, and if the filesystem
   --  ever puts it somewhere new the old copy stays behind in a block
   --  nothing has reused. A search that took the first match would find
   --  that one — at a lower block, so first — rewrite it, and leave the
   --  live file untouched: a failure in the third turn that looks like the
   --  driver and the filesystem disagreeing when nothing of the sort has
   --  happened. A token no earlier run used cannot be found by mistake.
   Filesystem_Prefix : constant String :=
     "flyology-device: written through a file, sought by a driver, run ";
   Driver_Prefix : constant String :=
     "flyology-device: written by a driver, read back as a file, run   ";

   pragma Compile_Time_Error
     (Filesystem_Prefix'Length /= Driver_Prefix'Length,
      "the two payloads must be the same length");

   --  Six characters, whatever the harness supplied. A token of another
   --  length would make the two payloads differ in length again, which the
   --  check above cannot catch because this part is not known until it
   --  runs.
   function Token return String is
      Given : constant String :=
        (if Ada.Environment_Variables.Exists ("FLYOLOGY_DEVICE_FS_TOKEN")
         then Ada.Environment_Variables.Value ("FLYOLOGY_DEVICE_FS_TOKEN")
         else "");
      Room  : String (1 .. 6) := [others => '0'];
      Taken : constant Natural := Natural'Min (Given'Length, 6);
   begin
      Room (1 .. Taken) := Given (Given'First .. Given'First + Taken - 1);
      return Room;
   end Token;

   Written_By_Filesystem : constant String := Filesystem_Prefix & Token;
   Written_By_Driver     : constant String := Driver_Prefix & Token;

   Scratch_Bytes : constant := 128 * 1024;

   function Mode return String is
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "");


   procedure Write_Through_File;
   procedure Read_Through_File;
   procedure Find_And_Rewrite;

   ------------------------------
   -- Write_Through_File --
   ------------------------------

   procedure Write_Through_File is
      File : Files.File_Descriptor;
      Item : Ada.Streams.Stream_Element_Array
        (1 .. Written_By_Filesystem'Length);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      for Index in Written_By_Filesystem'Range loop
         Item (Ada.Streams.Stream_Element_Offset
                 (Index - Written_By_Filesystem'First + 1)) :=
           Character'Pos (Written_By_Filesystem (Index));
      end loop;

      File := Files.Open
        (File_Path, Files.Write_Only, Create => True, Truncate => True);
      Files.Write_At (File, 0, Item, Last);
      Files.Close (File);

      Harness.Check
        (Last = Item'Last,
         "a file was written on a filesystem mounted on the namespace,"
         & " through the same file interface any program would use");
   end Write_Through_File;

   -----------------------------
   -- Read_Through_File --
   -----------------------------

   procedure Read_Through_File is
      File : Files.File_Descriptor;
      Item : Ada.Streams.Stream_Element_Array
        (1 .. Written_By_Driver'Length) := [others => 0];
      Last : Ada.Streams.Stream_Element_Offset;
      Matches : Boolean := True;
   begin
      File := Files.Open (File_Path, Files.Read_Only);
      Files.Read_At (File, 0, Item, Last);
      Files.Close (File);

      Harness.Check
        (Last = Item'Last,
         "the file is still there and still the length it was");

      for Index in Written_By_Driver'Range loop
         if Item (Ada.Streams.Stream_Element_Offset
                    (Index - Written_By_Driver'First + 1))
           /= Character'Pos (Written_By_Driver (Index))
         then
            Matches := False;
         end if;
      end loop;

      Harness.Check
        (Matches,
         "and reading it returns what the driver wrote rather than what the"
         & " filesystem put there — so the block this driver chose and the"
         & " block the filesystem chose are the same block");
   end Read_Through_File;

   ----------------------------
   -- Find_And_Rewrite --
   ----------------------------

   procedure Find_And_Rewrite is
      Address : constant String :=
        Find (Controller.Vendor_ID, Controller.Device_ID);
      Container : Container_FD;
      Group     : Group_FD;
      Device    : Device_FD;
   begin
      Harness.Note ("device at " & Address);

      Containers.Open (Container);
      Groups.Open (Group, Groups.Group_Of (Address));
      Groups.Attach (Group, Container);
      Containers.Set_IOMMU (Container);
      Devices.Open (Device, Group, Container, Address);
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

               Volume : Disk.Volume;
               Host : constant System.Address :=
                 DMA.Regions.Base_Address (Area);
            begin
               Disk.Open
                 (Volume, BAR, Host, Window_Base, Scratch_Bytes,
                  Namespace);
               Harness.Check
                 (Volume.Is_Open,
                  "the namespace the filesystem lives on opened as a"
                  & " volume");
               Harness.Note
                 ("it holds" & U64'Image (Volume.Block_Count)
                  & " blocks of" & Positive'Image (Volume.Block_Bytes)
                  & " bytes");

               declare
                  --  A window at a time, overlapping by the length of what
                  --  is being looked for, so that a payload lying across a
                  --  window boundary is still found whole.
                  Step   : constant Natural := 64 * 1024;
                  Overlap : constant Natural := Written_By_Filesystem'Length;
                  Blocks_Per_Step : constant U64 :=
                    U64 (Step / Volume.Block_Bytes);
                  Window : Disk.Byte_Sequence (0 .. Step - 1);
                  At_Block : U64 := 0;
                  Found_At : U64 := 0;
                  Found_In : Natural := 0;
                  Found    : Boolean := False;
               begin
                  Search :
                  while not Found
                    and then At_Block + Blocks_Per_Step <= Volume.Block_Count
                  loop
                     Volume.Read (BAR, At_Block, Window);

                     for Start in 0 .. Step - Overlap loop
                        declare
                           Same : Boolean := True;
                        begin
                           for Index in 0 .. Overlap - 1 loop
                              if Window (Start + Index)
                                /= U8 (Character'Pos
                                         (Written_By_Filesystem
                                            (Written_By_Filesystem'First
                                             + Index)))
                              then
                                 Same := False;
                                 exit;
                              end if;
                           end loop;
                           if Same then
                              Found := True;
                              Found_At := At_Block;
                              Found_In := Start;
                              exit Search;
                           end if;
                        end;
                     end loop;

                     --  Step back by less than a whole window, so nothing
                     --  straddling the seam is missed.
                     At_Block := At_Block + Blocks_Per_Step
                                 - U64 (Overlap / Volume.Block_Bytes) - 1;
                  end loop Search;

                  Harness.Check
                    (Found,
                     "the driver found, by reading the medium, the bytes a"
                     & " file put there — without parsing a filesystem, so"
                     & " what it establishes is that the medium is the same"
                     & " medium and not that the layout was guessed right");

                  if Found then
                     Harness.Note
                       ("at block" & U64'Image (Found_At) & " plus"
                        & Natural'Image (Found_In) & " bytes");

                     Volume.Read (BAR, Found_At, Window);
                     for Index in 0 .. Overlap - 1 loop
                        Window (Found_In + Index) :=
                          U8 (Character'Pos
                                (Written_By_Driver
                                   (Written_By_Driver'First + Index)));
                     end loop;
                     Volume.Write (BAR, Found_At, Window);
                     Volume.Flush (BAR);

                     Harness.Check
                       (True,
                        "and wrote different bytes over them, which the"
                        & " next turn reads back through the file");
                  end if;
               end;

               Disk.Close (Volume, BAR);
            end;

            Config.Disable_Bus_Mastering (Device);
         end;
      end;
   end Find_And_Rewrite;
begin
   if Mode = "write" then
      Write_Through_File;
   elsif Mode = "find" then
      Find_And_Rewrite;
   elsif Mode = "read" then
      Read_Through_File;
   else
      Harness.Skip
        ("every check",
         "this takes one of write, find or read; the harness runs all"
         & " three in that order, giving the namespace to the kernel, then"
         & " to this driver, then back");
   end if;

   Harness.Report ("nvme_file_tests " & Mode);

exception
   when Error : Device_Not_Available =>
      Harness.Skip ("every check", Ada.Exceptions.Exception_Message (Error));
      Harness.Report ("nvme_file_tests " & Mode);
end NVMe_File_Tests;
