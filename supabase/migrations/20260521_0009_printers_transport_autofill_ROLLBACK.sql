-- Rollback de `20260521_0009_printers_transport_autofill.sql`.
--
-- IMPORTANTE: si el código legacy (createPrinter sin setear transport)
-- sigue desplegado, después del rollback los INSERT volverán a fallar.

begin;

drop trigger if exists trg_printer_autofill_transport on public.printers;
drop function if exists public.fn_printer_autofill_transport();

commit;
