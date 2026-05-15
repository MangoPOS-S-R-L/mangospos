-- Rollback de `20260516_0011_physical_count.sql`.
-- ⚠️ Los movimientos en inventory_movements con reference_type='physical_count'
-- NO se borran: el stock ya reflejó los ajustes. Solo se borran las sesiones
-- y líneas (rastro/audit del conteo).

begin;
drop view if exists public.v_physical_count_sessions_summary;
drop function if exists public.fn_physical_count_cancel(uuid, text);
drop function if exists public.fn_physical_count_complete(uuid);
drop function if exists public.fn_physical_count_set_count(uuid, uuid, numeric, text);
drop function if exists public.fn_physical_count_freeze(uuid);
drop function if exists public.fn_physical_count_create(uuid, uuid, text);
drop trigger if exists trg_physical_count_assign_code on public.physical_count_sessions;
drop function if exists public.fn_physical_count_assign_code();
drop table if exists public.physical_count_lines;
drop table if exists public.physical_count_sessions;
commit;
