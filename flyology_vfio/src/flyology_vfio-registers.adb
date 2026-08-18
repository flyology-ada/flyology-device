pragma Warnings (Off, "*internal GNAT unit*");
pragma Warnings (Off, "*non-portable*");
with System;
with System.Atomic_Primitives;
with System.Storage_Elements;

package body Flyology_VFIO.Registers is

   package AP renames System.Atomic_Primitives;
   package SSE renames System.Storage_Elements;

   use type SSE.Storage_Offset;

   --  GCC's standalone barrier. It is imported here rather than taken from
   --  System.Atomic_Primitives because that package binds the loads, stores
   --  and compare-exchanges but not the fence.
   procedure Thread_Fence (Model : AP.Mem_Model);
   pragma Import (Intrinsic, Thread_Fence, "__atomic_thread_fence");

   --  Whole-object overlay types. Volatile_Full_Access is what makes an
   --  access a single load or store of the whole object: plain Volatile
   --  permits the compiler to touch a record's components separately, which
   --  on a device register means several bus transactions where the
   --  specification described one. Volatile_Full_Access is limited to
   --  objects that fit a machine scalar, which is another reason the widths
   --  here stop at 64 bits.
   type Reg_8 is mod 2 ** 8 with Size => 8, Volatile_Full_Access;
   type Reg_16 is mod 2 ** 16 with Size => 16, Volatile_Full_Access;
   type Reg_32 is mod 2 ** 32 with Size => 32, Volatile_Full_Access;
   type Reg_64 is mod 2 ** 64 with Size => 64, Volatile_Full_Access;

   function At_Address
     (Window : Regions.Window; At_Offset : Offset) return System.Address
   is (Regions.Base (Window) + SSE.Storage_Offset (At_Offset));

   -------------
   -- Read_32 --
   -------------

   function Read_32 (From : Regions.Window; At_Offset : Offset) return U32 is
      Cell : Reg_32 with Import, Address => At_Address (From, At_Offset);
   begin
      return U32 (Cell);
   end Read_32;

   --------------
   -- Write_32 --
   --------------

   procedure Write_32
     (Into : Regions.Window; At_Offset : Offset; Value : U32)
   is
      Cell : Reg_32 with Import, Address => At_Address (Into, At_Offset);
   begin
      Cell := Reg_32 (Value);
   end Write_32;

   -------------
   -- Read_64 --
   -------------

   function Read_64 (From : Regions.Window; At_Offset : Offset) return U64 is
      Cell : Reg_64 with Import, Address => At_Address (From, At_Offset);
   begin
      return U64 (Cell);
   end Read_64;

   --------------
   -- Write_64 --
   --------------

   procedure Write_64
     (Into : Regions.Window; At_Offset : Offset; Value : U64)
   is
      Cell : Reg_64 with Import, Address => At_Address (Into, At_Offset);
   begin
      Cell := Reg_64 (Value);
   end Write_64;

   -------------
   -- Read_16 --
   -------------

   function Read_16 (From : Regions.Window; At_Offset : Offset) return U16 is
      Cell : Reg_16 with Import, Address => At_Address (From, At_Offset);
   begin
      return U16 (Cell);
   end Read_16;

   --------------
   -- Write_16 --
   --------------

   procedure Write_16
     (Into : Regions.Window; At_Offset : Offset; Value : U16)
   is
      Cell : Reg_16 with Import, Address => At_Address (Into, At_Offset);
   begin
      Cell := Reg_16 (Value);
   end Write_16;

   ------------
   -- Read_8 --
   ------------

   function Read_8 (From : Regions.Window; At_Offset : Offset) return U8 is
      Cell : Reg_8 with Import, Address => At_Address (From, At_Offset);
   begin
      return U8 (Cell);
   end Read_8;

   -------------
   -- Write_8 --
   -------------

   procedure Write_8 (Into : Regions.Window; At_Offset : Offset; Value : U8)
   is
      Cell : Reg_8 with Import, Address => At_Address (Into, At_Offset);
   begin
      Cell := Reg_8 (Value);
   end Write_8;

   ---------------------
   -- Read_Acquire_32 --
   ---------------------

   --  AP.Acquire is a named constant, so the builtin sees a compile-time
   --  memory model and emits the ordered instruction. Passing a variable
   --  here would compile and silently degrade to sequential consistency.

   function Read_Acquire_32
     (From : Regions.Window; At_Offset : Offset) return U32
   is (U32 (AP.Atomic_Load_32 (At_Address (From, At_Offset), AP.Acquire)));

   -----------------------
   -- Write_Release_32 --
   -----------------------

   procedure Write_Release_32
     (Into : Regions.Window; At_Offset : Offset; Value : U32)
   is
   begin
      AP.Atomic_Store_32
        (At_Address (Into, At_Offset), AP.uint32 (Value), AP.Release);
   end Write_Release_32;

   ---------------------
   -- Read_Acquire_64 --
   ---------------------

   function Read_Acquire_64
     (From : Regions.Window; At_Offset : Offset) return U64
   is (U64 (AP.Atomic_Load_64 (At_Address (From, At_Offset), AP.Acquire)));

   -----------------------
   -- Write_Release_64 --
   -----------------------

   procedure Write_Release_64
     (Into : Regions.Window; At_Offset : Offset; Value : U64)
   is
   begin
      AP.Atomic_Store_64
        (At_Address (Into, At_Offset), AP.uint64 (Value), AP.Release);
   end Write_Release_64;

   -----------------
   -- Store_Fence --
   -----------------

   procedure Store_Fence is
   begin
      Thread_Fence (AP.Release);
   end Store_Fence;

   ----------------
   -- Load_Fence --
   ----------------

   procedure Load_Fence is
   begin
      Thread_Fence (AP.Acquire);
   end Load_Fence;

   ----------------
   -- Full_Fence --
   ----------------

   procedure Full_Fence is
   begin
      Thread_Fence (AP.Seq_Cst);
   end Full_Fence;

end Flyology_VFIO.Registers;
