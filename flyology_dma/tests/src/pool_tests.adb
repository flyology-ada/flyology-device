--  Exercises buffer pools.
--
--  A pool's job is to hand out a pair of addresses for the same bytes and to
--  never hand the same bytes to two callers. The checks below concentrate on
--  the second half: exhaustion, double release, and handles that did not
--  come from this pool. Each of those, if accepted, puts two writers and a
--  device on one buffer with nothing left to report the collision.

with Flyology_DMA;
with Flyology_DMA.Mappers;
with Flyology_DMA.Pools;
with Flyology_DMA.Regions;
with Flyology_DMA.Thin;
with Support;
with System;
with System.Storage_Elements;

procedure Pool_Tests is
   use Flyology_DMA;
   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;

   package M renames Flyology_DMA.Mappers;
   package P renames Flyology_DMA.Pools;
   use type P.Buffer_Index;

   Page       : constant Byte_Count := Thin.Page_Size (Regular_Pages);
   Base_IOVA  : constant IOVA_Address := 16#2000_0000#;
   Count      : constant P.Buffer_Index := 8;
   Buffer_Len : constant Byte_Count := 256;

   Backend : aliased M.Identity_Mapper;
   Region  : Regions.Region := Regions.Create (Page * 4, Regular_Pages);
   Bound   : M.Mapping := M.Map_Region (Backend'Access, Region, Base_IOVA);
   Buffers : P.Pool (Count);

   First, Second : P.Buffer_Handle;
   Got : Boolean;
begin
   P.Configure (Buffers, Bound, Buffer_Len);
   Support.Check (P.Is_Configured (Buffers), "the pool is laid out");
   Support.Check
     (P.Buffer_Size (Buffers) = Buffer_Len, "it reports the buffer size");
   Support.Check
     (P.Stride (Buffers) = 256, "a 256-byte buffer needs no cache padding");
   Support.Check
     (P.Available (Buffers) = Natural (Count), "every buffer is free");

   P.Acquire (Buffers, First, Got);
   Support.Check (Got, "the first buffer is available");
   Support.Check
     (First.Host = Regions.Base_Address (Region),
      "the first buffer starts at the region base");
   Support.Check
     (First.IOVA = Base_IOVA, "its IOVA starts at the mapping base");
   Support.Check (First.Length = Buffer_Len, "it carries its length");
   Support.Check
     (P.Available (Buffers) = Natural (Count) - 1, "one buffer is out");

   P.Acquire (Buffers, Second, Got);
   Support.Check (Got, "the second buffer is available");
   Support.Check
     (Second.Host = First.Host + System.Storage_Elements.Storage_Offset
        (P.Stride (Buffers)),
      "the second buffer follows the first in host memory");
   Support.Check
     (Second.IOVA = First.IOVA + IOVA_Address (P.Stride (Buffers)),
      "and by the same distance in device memory");
   Support.Check
     (Second.Index /= First.Index, "the two buffers are different slots");

   --  The two addresses of one buffer must stay a fixed distance apart, and
   --  Offset is the only way to move within a buffer precisely so that they
   --  cannot drift.
   declare
      Interior : constant P.Buffer_Handle := P.Offset (First, 64);
   begin
      Support.Check
        (Interior.Host = First.Host + 64, "Offset advances the host address");
      Support.Check
        (Interior.IOVA = First.IOVA + 64, "and the device address with it");
      Support.Check
        (Interior.Length = Buffer_Len - 64, "and shrinks the length");
      Support.Check
        (Interior.Index = First.Index, "and keeps naming the same slot");
      Support.Check
        (Mirrored (Interior.Host) - Mirrored (First.Host)
           = Interior.IOVA - First.IOVA,
         "both addresses moved by the same amount");
   end;

   --  Exhaustion is reported rather than raised: a driver out of receive
   --  buffers drops a packet and carries on.
   declare
      Held : array (1 .. Natural (Count)) of P.Buffer_Handle;
      Have : Natural := 2;
      Extra : P.Buffer_Handle;
      Fit : Boolean;
   begin
      Held (1) := First;
      Held (2) := Second;
      loop
         P.Acquire (Buffers, Extra, Fit);
         exit when not Fit;
         Have := Have + 1;
         Held (Have) := Extra;
      end loop;
      Support.Check
        (Have = Natural (Count), "the pool handed out exactly its capacity");
      Support.Check (P.Available (Buffers) = 0, "nothing is left");

      --  Every buffer handed out must be distinct. Two acquires returning
      --  one buffer is the failure this whole type exists to prevent.
      declare
         All_Distinct : Boolean := True;
      begin
         for I in 1 .. Have loop
            for J in 1 .. Have loop
               if I /= J and then Held (I).Host = Held (J).Host then
                  All_Distinct := False;
               end if;
            end loop;
         end loop;
         Support.Check (All_Distinct, "no two buffers share an address");
      end;

      for I in 1 .. Have loop
         P.Release (Buffers, Held (I));
      end loop;
      Support.Check
        (P.Available (Buffers) = Natural (Count), "everything came back");
   end;

   --  Releasing a buffer twice must be refused, not absorbed.
   declare
      Handle : P.Buffer_Handle;
      Raised : Boolean := False;
      Taken  : Boolean;
   begin
      P.Acquire (Buffers, Handle, Taken);
      Support.Check (Taken, "a buffer is available for the double release");
      P.Release (Buffers, Handle);
      begin
         P.Release (Buffers, Handle);
      exception
         when Pool_Error =>
            Raised := True;
      end;
      Support.Check_Raised (Raised, "a double release is refused");
      Support.Check
        (P.Available (Buffers) = Natural (Count),
         "the refused release did not change the count");
   end;

   --  A handle from somewhere else must not be accepted, because releasing
   --  it would free a buffer this pool believes is still in use.
   declare
      Foreign : constant P.Buffer_Handle :=
        (Host   => System.Storage_Elements.To_Address (16#DEAD_0000#),
         IOVA   => 0,
         Length => Buffer_Len,
         Index  => 1);
      Raised : Boolean := False;
   begin
      P.Release (Buffers, Foreign);
   exception
      when Pool_Error =>
         Raised := True;
         Support.Check_Raised (Raised, "a foreign handle is refused");
   end;

   --  A pool that does not fit its mapping is refused rather than truncated.
   declare
      Too_Big : P.Pool (1024);
      Raised  : Boolean := False;
   begin
      P.Configure (Too_Big, Bound, Page * 4);
   exception
      when Pool_Error =>
         Raised := True;
         Support.Check_Raised
           (Raised, "a pool larger than its mapping is refused");
   end;

   --  Buffers are cache-line aligned by default, so two buffers in use by
   --  different parts of a driver do not share a line.
   declare
      Padded : P.Pool (4);
      Handle : P.Buffer_Handle;
      Taken  : Boolean;
   begin
      P.Configure (Padded, Bound, 100);
      Support.Check
        (P.Stride (Padded) = 128, "a 100-byte buffer strides by 128");
      P.Acquire (Padded, Handle, Taken);
      Support.Check (Taken and then Handle.Length = 100,
                     "the usable length is what was asked for");
   end;

   Support.Report ("pool_tests");
end Pool_Tests;
