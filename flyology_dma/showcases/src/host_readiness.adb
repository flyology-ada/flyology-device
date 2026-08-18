--  Reports what this host can currently support for DMA memory.
--
--  Run before anything else on an unfamiliar machine. It changes nothing:
--  reserving hugepages and raising the locked-memory limit are decisions for
--  whoever owns the machine, and this only says what is missing.

with Ada.Text_IO;
with Flyology_DMA.Environment;

procedure Host_Readiness is
begin
   Ada.Text_IO.Put (Flyology_DMA.Environment.Summary);
end Host_Readiness;
