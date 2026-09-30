-- ROLLBACK de 20260930_0050_inventory_yield_analysis.sql
-- Solo quita la función (solo lee; no dejó datos). La columna reason_code se
-- queda: es de 20260513_0017 y la usan los ajustes y las salidas.

begin;

drop function if exists public.fn_inventory_yield_analysis(uuid, int, uuid);

notify pgrst, 'reload schema';

commit;
