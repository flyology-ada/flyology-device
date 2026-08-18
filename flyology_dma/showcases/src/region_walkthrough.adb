--  Walks through the whole crate: region, IOVA, mapping, pool, buffer.
--
--  This is what a driver's start-up does, minus the driver. It uses the
--  identity mapper, so nothing is programmed into any IOMMU and no device
--  ever sees the addresses printed here; substituting a real mapper is the
--  only change needed to make it drive hardware.

with Ada.Command_Line;
with Ada.Text_IO;
with Flyology_DMA;
with Flyology_DMA.Address_Space;
with Flyology_DMA.Environment;
with Flyology_DMA.Mappers;
with Flyology_DMA.Pools;
with Flyology_DMA.Regions;

procedure Region_Walkthrough is
   use Flyology_DMA;

   package AS renames Flyology_DMA.Address_Space;
   package Env renames Flyology_DMA.Environment;
   package IO renames Ada.Text_IO;
   package M renames Flyology_DMA.Mappers;
   package P renames Flyology_DMA.Pools;

   --  Hugepages where the host has them, ordinary pages otherwise. A driver
   --  would not make this choice at run time: it would demand hugepages and
   --  fail if the host had none. A showcase that refused to run on a laptop
   --  would show nothing.
   Backing : constant Region_Backing :=
     (if Env.Report (Huge_2M).Supported
        and then Env.Report (Huge_2M).Pages_Free > 0
      then Huge_2M
      else Regular_Pages);

   --  An IOVA window a device would be told about. The address is arbitrary
   --  and deliberately unlike any host address, so that a value printed
   --  below is obviously one or the other.
   Window_Base   : constant IOVA_Address := 16#0000_4000_0000_0000#;
   Window_Length : constant Byte_Count := 64 * 1024 * 1024;

   Space   : AS.Allocator;
   Backend : aliased M.Identity_Mapper;
begin
   IO.Put_Line ("backing            " & Region_Backing'Image (Backing));

   AS.Configure_Window (Space, Window_Base, Window_Length, 4096);

   declare
      Area : constant Regions.Region := Regions.Create (1024 * 1024, Backing);
      Where : IOVA_Address;
      Fits  : Boolean;
   begin
      IO.Put_Line ("region length     " & Byte_Count'Image
                     (Regions.Length (Area)));
      IO.Put_Line ("region page size  " & Byte_Count'Image
                     (Regions.Page_Size (Area)));

      AS.Allocate
        (Space, Regions.Length (Area),
         Alignment (Regions.Page_Size (Area)),
         Mirrored (Regions.Base_Address (Area)), Where, Fits);

      if not Fits then
         IO.Put_Line ("the IOVA window could not fit the region");
         Ada.Command_Line.Set_Exit_Status (1);
         return;
      end if;

      declare
         --  Declared after the region, so it is finalized before it. The
         --  device-visible mapping goes away while the memory behind it
         --  still exists, which is the order that matters.
         Bound : constant M.Mapping :=
           M.Map_Region (Backend'Access, Area, Where, M.Device_Writes);

         Buffers : P.Pool (256);
         Handle  : P.Buffer_Handle;
         Taken   : Boolean;
      begin
         IO.Put_Line ("mapped at IOVA    " & IOVA_Address'Image
                        (M.IOVA_Base (Bound)));

         P.Configure (Buffers, Bound, 2048);
         IO.Put_Line ("pool buffers      " & Natural'Image
                        (P.Available (Buffers)));
         IO.Put_Line ("pool stride       " & Byte_Count'Image
                        (P.Stride (Buffers)));

         P.Acquire (Buffers, Handle, Taken);
         if not Taken then
            IO.Put_Line ("the pool was empty, which cannot happen here");
            Ada.Command_Line.Set_Exit_Status (1);
            return;
         end if;

         --  The pair of addresses is the point. A descriptor written for a
         --  device carries the IOVA; a memcpy into the buffer uses the host
         --  address. They name the same bytes and are not interchangeable.
         IO.Put_Line ("buffer IOVA       " & IOVA_Address'Image (Handle.IOVA));
         IO.Put_Line ("buffer host       " & IOVA_Address'Image
                        (Mirrored (Handle.Host)));
         IO.Put_Line ("buffer length     " & Byte_Count'Image
                        (Handle.Length));

         declare
            Payload : String (1 .. 5) with Import, Address => Handle.Host;
         begin
            Payload := "hello";
            IO.Put_Line ("wrote             " & Payload);
         end;

         P.Release (Buffers, Handle);
         IO.Put_Line ("after release     " & Natural'Image
                        (P.Available (Buffers)) & " buffers free");
      end;

      IO.Put_Line ("mapping released, region still live");
   end;

   IO.Put_Line ("region released");
end Region_Walkthrough;
