with Flyology_DMA.Thin;

package body Flyology_DMA.Environment is

   ------------
   -- Report --
   ------------

   function Report (Backing : Region_Backing) return Backing_Report is
     (Supported   => Thin.Supports (Backing),
      Page_Size   => Thin.Page_Size (Backing),
      Pages_Total => Thin.Hugepages_Total (Backing),
      Pages_Free  => Thin.Hugepages_Free (Backing));

   -----------------------
   -- Memory_Lock_Limit --
   -----------------------

   function Memory_Lock_Limit return Byte_Count is (Thin.Memory_Lock_Limit);

   -------------
   -- Summary --
   -------------

   function Summary return String is
      LF : constant Character := ASCII.LF;

      function Backing_Line (Backing : Region_Backing) return String is
         State : constant Backing_Report := Report (Backing);
      begin
         if not State.Supported then
            return "  " & Region_Backing'Image (Backing) & ": unavailable — "
              & Thin.Unsupported_Reason (Backing) & LF;
         end if;

         if Backing = Regular_Pages then
            return "  " & Region_Backing'Image (Backing) & ": available,"
              & Byte_Count'Image (State.Page_Size) & " byte pages." & LF;
         end if;

         return "  " & Region_Backing'Image (Backing) & ": available,"
           & Natural'Image (State.Pages_Free) & " free of"
           & Natural'Image (State.Pages_Total) & " reserved pages of"
           & Byte_Count'Image (State.Page_Size) & " bytes."
           & (if State.Pages_Free = 0
              then " Reserve some before creating a region of this backing."
              else "")
           & LF;
      end Backing_Line;

      Limit : constant Byte_Count := Memory_Lock_Limit;
   begin
      return "Flyology DMA host readiness" & LF
        & "Region backings:" & LF
        & Backing_Line (Regular_Pages)
        & Backing_Line (Huge_2M)
        & Backing_Line (Huge_1G)
        & "Locked memory limit: "
        & (if Limit = Byte_Count'Last
           then "unlimited"
           else Byte_Count'Image (Limit) & " bytes")
        & LF
        & "  A mapper pins the memory it maps against this limit, so a low"
        & LF
        & "  limit appears as a failure to map rather than to allocate."
        & LF
        & "  Raise it with: ulimit -l <kibibytes>, or grant CAP_IPC_LOCK."
        & LF;
   end Summary;

end Flyology_DMA.Environment;
