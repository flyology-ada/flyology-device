--  Deciding which device-visible address a region gets.
--
--  An IOVA is a name, not a discovery: something has to choose it, and the
--  choice has consequences a caller should not stumble into. This package
--  makes the strategy an explicit decision at construction, with no default
--  that could silently change what a device sees.
--
--  The two strategies differ in what can go wrong with them. A bump window
--  hands out addresses from a range the caller nominated, so the caller
--  knows the range is free of whatever the platform has reserved. Mirroring
--  host addresses is convenient and needs no bookkeeping, but process
--  virtual addresses can land inside ranges the IOMMU has reserved — the
--  interrupt-remapping window on x86 is the usual one — and the mapping
--  then fails at a distance from the choice that caused it.
--
--  This package is written for proof: it manipulates only integers, holds no
--  addresses, and allocates nothing. The contracts state that a successful
--  allocation lies inside the window, is aligned as asked, and does not
--  overlap anything handed out before it. That is the property worth
--  proving here, because an IOVA that runs past the end of its window is a
--  device write into memory nobody mapped.
package Flyology_DMA.Address_Space
  with SPARK_Mode => On
is

   --  The postcondition of Allocate compares the window against its entry
   --  state inside a conditional, which makes those 'Old prefixes
   --  potentially unevaluated. Evaluating them eagerly is safe here: the
   --  observers below are total, so none of them can fail on a state where
   --  the branch would not have asked for them.
   pragma Unevaluated_Use_Of_Old (Allow);

   --  How a device-visible address is chosen.
   --
   --  @enum Bump_Window Addresses are taken in order from a caller-supplied
   --    IOVA range. Nothing is ever reused; the window is sized for the
   --    lifetime of the device.
   --  @enum Mirror_Host_Addresses The IOVA is the numeric value of the host
   --    virtual address. Meaningful only where the IOMMU has been programmed
   --    for identity mapping, or where nothing consumes the IOVA at all.
   type Assignment is (Bump_Window, Mirror_Host_Addresses);

   --  Assigns device-visible addresses by one explicitly chosen strategy.
   type Allocator is limited private;

   --  Whether a strategy has been chosen for this allocator.
   --  @param Self The allocator
   --  @return True once one of the Configure procedures has run
   function Is_Configured (Self : Allocator) return Boolean;

   --  The strategy this allocator was configured with.
   --  @param Self The allocator
   --  @return The chosen strategy
   function Strategy (Self : Allocator) return Assignment;

   --  The first address of the window.
   --  Zero unless the allocator was configured as a bump window.
   --  @param Self The allocator
   --  @return Base of the IOVA window
   function Window_Base (Self : Allocator) return IOVA_Address;

   --  The size of the window in bytes.
   --  Zero unless the allocator was configured as a bump window.
   --  @param Self The allocator
   --  @return Length of the IOVA window
   function Window_Length (Self : Allocator) return Byte_Count;

   --  How much of the window has been handed out, in bytes.
   --
   --  Includes alignment padding, so it is what the window has lost rather
   --  than the sum of the lengths requested.
   --
   --  @param Self The allocator
   --  @return Bytes consumed from the window
   function Used (Self : Allocator) return Byte_Count
     with Post => Used'Result <= Window_Length (Self);

   --  Configures an allocator to hand out addresses from a window.
   --
   --  The window must not wrap the address space, and its base must be
   --  aligned to the granularity. Nothing is reused: once handed out, an
   --  address stays handed out for the life of the allocator. That is a
   --  deliberate simplification, because a driver's DMA regions are
   --  established at start-up and released at shutdown, and a free-list of
   --  IOVA ranges would be complexity in service of a case that does not
   --  arise yet.
   --
   --  @param Self The allocator to configure
   --  @param Base First address of the window
   --  @param Length Size of the window in bytes
   --  @param Granularity Smallest unit the IOMMU maps; allocations are
   --    rounded up to it
   procedure Configure_Window
     (Self        : out Allocator;
      Base        : IOVA_Address;
      Length      : Byte_Count;
      Granularity : Alignment)
     with
       Pre  =>
         Length > 0
         and then Is_Power_Of_Two (Granularity)
         and then Base <= IOVA_Address'Last - IOVA_Address (Length)
         and then Base mod IOVA_Address (Granularity) = 0
         and then Length mod Byte_Count (Granularity) = 0,
       Post =>
         Is_Configured (Self)
         and then Strategy (Self) = Bump_Window
         and then Window_Base (Self) = Base
         and then Window_Length (Self) = Length
         and then Used (Self) = 0;

   --  Configures an allocator to mirror host addresses.
   --  @param Self The allocator to configure
   procedure Configure_Mirror (Self : out Allocator)
     with
       Post =>
         Is_Configured (Self)
         and then Strategy (Self) = Mirror_Host_Addresses;

   --  Chooses a device-visible address for one region.
   --
   --  Host_Value is the host virtual address expressed as a number, as
   --  Flyology_DMA.Mirrored produces. The bump-window strategy ignores it;
   --  the mirror strategy returns it. Passing it always keeps one call shape
   --  for both strategies, so switching strategy is a one-line change at
   --  construction rather than a change at every call.
   --
   --  Failure to fit is reported through Succeeded rather than raised: an
   --  exhausted window is a sizing decision the caller made, and a driver
   --  setting up its regions can report all of what it could not fit at
   --  once.
   --
   --  @param Self The allocator
   --  @param Length Size of the region in bytes
   --  @param Align_To Alignment the address must satisfy
   --  @param Host_Value The host address as a number, for the mirror strategy
   --  @param IOVA The chosen address, when Succeeded
   --  @param Succeeded False when the window cannot fit the request
   procedure Allocate
     (Self       : in out Allocator;
      Length     : Byte_Count;
      Align_To   : Alignment;
      Host_Value : IOVA_Address;
      IOVA       : out IOVA_Address;
      Succeeded  : out Boolean)
     with
       Pre  =>
         Is_Configured (Self)
         and then Length > 0
         and then Is_Power_Of_Two (Align_To),
       Post =>
         Strategy (Self) = Strategy (Self)'Old
         and then Is_Configured (Self)
         and then
           (if Strategy (Self) = Mirror_Host_Addresses
            then Succeeded and then IOVA = Host_Value)
         and then
           (if Strategy (Self) = Bump_Window then
              Window_Base (Self) = Window_Base (Self)'Old
              and then Window_Length (Self) = Window_Length (Self)'Old
              and then
                (if Succeeded then
                   --  Inside the window, aligned, and wholly contained.
                   IOVA >= Window_Base (Self)
                   and then IOVA - Window_Base (Self)
                              <= IOVA_Address (Used (Self)) - IOVA_Address (Length)
                   and then IOVA mod IOVA_Address (Align_To) = 0
                   and then Used (Self) >= Used (Self)'Old + Length
                 else Used (Self) = Used (Self)'Old));

private

   type Allocator is limited record
      Configured : Boolean      := False;
      Approach   : Assignment   := Bump_Window;
      Base       : IOVA_Address := 0;
      Extent     : Byte_Count   := 0;
      Consumed   : Byte_Count   := 0;
   end record
     with Predicate =>
       (if Configured and then Approach = Bump_Window
        then Consumed <= Extent
             and then Extent > 0
             and then Base <= IOVA_Address'Last - IOVA_Address (Extent));

   function Is_Configured (Self : Allocator) return Boolean is
     (Self.Configured);

   function Strategy (Self : Allocator) return Assignment is (Self.Approach);

   function Window_Base (Self : Allocator) return IOVA_Address is (Self.Base);

   function Window_Length (Self : Allocator) return Byte_Count is
     (Self.Extent);

   function Used (Self : Allocator) return Byte_Count is (Self.Consumed);

end Flyology_DMA.Address_Space;
