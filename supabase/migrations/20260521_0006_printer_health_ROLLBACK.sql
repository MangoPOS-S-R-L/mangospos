-- Rollback de `20260521_0006_printer_health.sql`.

begin;

drop policy if exists "printer_health_select" on public.printer_health;

drop function if exists public.fn_report_printer_health(uuid, text, text, jsonb);

drop trigger if exists trg_printer_health_sync on public.printer_health;
drop function if exists public.fn_printer_health_sync();

drop table if exists public.printer_health;

commit;
