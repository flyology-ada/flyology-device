--  Reports whether this host can run anything in this crate, and changes
--  nothing.
--
--  Never unbinds a device, never loads a module, never writes to a kernel
--  parameter. Taking a device away from a running driver is a decision for
--  whoever owns the machine, and a script that made it silently could take
--  down the disk the machine is running from.

with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Flyology_DMA.Environment;
with Flyology_VFIO.Containers;

procedure Host_Readiness is
   package IO renames Ada.Text_IO;

   Problems : Natural := 0;

   procedure Report (Label : String; Present : Boolean; Advice : String) is
   begin
      IO.Put_Line ("  " & (if Present then "yes " else "NO  ") & Label);
      if not Present then
         Problems := Problems + 1;
         IO.Put_Line ("       " & Advice);
      end if;
   end Report;

   Groups_Dir : constant String := "/sys/kernel/iommu_groups";
   Have_Groups : constant Boolean :=
     Ada.Directories.Exists (Groups_Dir)
     and then not Ada.Directories.Exists (Groups_Dir & "/.empty");
begin
   IO.Put_Line ("Flyology VFIO host readiness");

   Report ("/dev/vfio exists",
           Ada.Directories.Exists ("/dev/vfio"),
           "load the module: modprobe vfio-pci");

   Report ("the container node " & Flyology_VFIO.Containers.Device_Node
           & " exists",
           Ada.Directories.Exists (Flyology_VFIO.Containers.Device_Node),
           "a kernel offering only /dev/vfio/devices has the newer IOMMUFD"
           & " interface, which this crate does not bind");

   Report ("an IOMMU is enabled",
           Have_Groups,
           "boot with intel_iommu=on or amd_iommu=on on x86; on arm64 the"
           & " SMMU must be described by firmware. " & Groups_Dir
           & " is empty or absent when it is not");

   IO.New_Line;
   IO.Put_Line ("Memory available for device access:");
   IO.Put (Flyology_DMA.Environment.Summary);

   IO.New_Line;
   if Problems = 0 then
      IO.Put_Line ("This host can open a VFIO container.");
      IO.Put_Line
        ("A device still has to be bound to vfio-pci before it can be"
         & " opened, which this program deliberately will not do for you.");
   else
      IO.Put_Line
        ("This host cannot open a VFIO container yet:"
         & Natural'Image (Problems) & " condition(s) above are unmet.");
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Host_Readiness;
