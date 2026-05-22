-- Rollback de `20260521_0004_device_printer_bindings.sql`.
--
-- Las vinculaciones se PIERDEN. Si había impresoras BT/USB en uso, el
-- agent ya no sabrá cuál device las controla y los print_jobs con
-- target_device_id quedarán sin atender.

begin;

drop policy if exists "device_printer_bindings_write"  on public.device_printer_bindings;
drop policy if exists "device_printer_bindings_select" on public.device_printer_bindings;

drop table if exists public.device_printer_bindings;

commit;
