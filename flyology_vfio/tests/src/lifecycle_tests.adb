--  Exercises what can be exercised without a device.
--
--  This program adapts to its host. On a machine with no VFIO — a macOS
--  development host, or a container whose kernel has no IOMMU — it checks
--  that every failure says what is missing and what would provide it, and
--  skips the rest by name. On a machine with VFIO it opens a real container
--  and checks the parts of the lifecycle that need no device.
--
--  What it cannot check either way is the interesting half: attaching a
--  group, setting the IOMMU, and mapping memory all need a device bound to
--  vfio-pci. Those live in the flyology_vfio_qemu crate, which drives real
--  virtual devices in a virtual machine. Nothing here pretends otherwise:
--  the skips are counted and printed.

with Ada.Directories;
with Ada.Exceptions;
with Flyology_VFIO;
with Flyology_VFIO.Containers;
with Flyology_VFIO.Groups;
with Support;

procedure Lifecycle_Tests is
   use Flyology_VFIO;

   Have_VFIO : constant Boolean :=
     Ada.Directories.Exists (Containers.Device_Node);

   --  A diagnostic earns its place by naming the condition and the fix. A
   --  one-line "operation failed" costs an hour in this domain, so the
   --  tests check that messages are substantial rather than checking their
   --  exact wording, which would make them brittle for no gain.
   Useful_Message_Length : constant := 60;
begin
   --  A device address that cannot exist. The group lookup must refuse it
   --  by name rather than returning something plausible.
   declare
      Refused : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Natural := Groups.Group_Of ("9999:99:99.9");
         begin
            Support.Check
              (Ignored = 0, "unreachable: that address cannot exist");
         end;
      exception
         when Error : VFIO_Unavailable =>
            Refused := True;
            Support.Check
              (Ada.Exceptions.Exception_Message (Error)'Length
                 > Useful_Message_Length,
               "the missing-device message explains the address format");
      end;
      Support.Check_Raised (Refused, "a nonexistent PCI address is refused");
   end;

   if not Have_VFIO then
      --  The interesting case for a development host: opening a container
      --  must fail with a message that distinguishes a missing module from
      --  a missing IOMMU from a kernel that only offers IOMMUFD.
      declare
         Refused : Boolean := False;
      begin
         begin
            declare
               Container : Container_FD;
            begin
               Containers.Open (Container);
            end;
         exception
            when Error : VFIO_Unavailable =>
               Refused := True;
               Support.Check
                 (Ada.Exceptions.Exception_Message (Error)'Length
                    > Useful_Message_Length,
                  "the unavailable message names what to load or enable");
         end;
         Support.Check_Raised
           (Refused, "opening a container without VFIO raises");
      end;

      Support.Skip
        ("container open, IOMMU checks",
         Containers.Device_Node & " is absent on this host");
      Support.Skip
        ("group attach and IOMMU set",
         "needs a device bound to vfio-pci");
      Support.Skip
        ("device open, BAR mapping, DMA mapping",
         "needs a device; the flyology_vfio_qemu crate covers these");
      Support.Report ("lifecycle_tests");
      return;
   end if;

   --  From here on the host has VFIO.
   declare
      Container : Container_FD;
   begin
      Containers.Open (Container);
      Support.Check (Containers.Is_Open (Container), "the container opened");
      Support.Check
        (Containers.Attached_Groups (Container) = 0,
         "a fresh container has no groups attached");
      Support.Check
        (not Containers.IOMMU_Is_Set (Container),
         "a fresh container has no IOMMU set");

      --  Set_IOMMU requires an attached group. That is a precondition
      --  rather than a comment precisely because the kernel's own refusal
      --  says nothing; here it is checked as a contract.
      Support.Check
        (not (Containers.Attached_Groups (Container) > 0),
         "Set_IOMMU's precondition is unmet, as it should be with no group");

      Containers.Close (Container);
      Support.Check
        (not Containers.Is_Open (Container), "the container closed");
   exception
      when Error : IOMMU_Unsupported =>
         Support.Skip
           ("container IOMMU checks",
            "this host has VFIO but not the type1 v2 IOMMU: "
            & Ada.Exceptions.Exception_Message (Error));
   end;

   Support.Skip
     ("group attach, device open, BAR and DMA mapping",
      "needs a device bound to vfio-pci; the flyology_vfio_qemu crate"
      & " covers these");

   Support.Report ("lifecycle_tests");
end Lifecycle_Tests;
