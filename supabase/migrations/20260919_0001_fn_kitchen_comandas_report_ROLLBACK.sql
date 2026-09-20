-- ROLLBACK de 20260919_0001 — quita la RPC del reporte de comandas.
-- No toca datos: la función solo lee.

begin;

drop function if exists public.fn_kitchen_comandas_report(uuid, timestamptz, timestamptz);
drop function if exists public.fn_kitchen_comandas_report(uuid, timestamptz, timestamptz, boolean);
drop function if exists public.fn_kitchen_comandas_report(uuid, timestamptz, timestamptz, boolean, boolean);

notify pgrst, 'reload schema';

commit;
