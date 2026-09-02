-- Rollback de 20260902_0013_inventory_opening_layers.sql
--
-- No borra las capas de apertura ya sembradas: eso lo hace el rollback de
-- 20260902_0012, o un delete explícito por source_type = 'opening'.

begin;

drop view if exists public.v_inventory_cost_shortfalls;
drop view if exists public.v_inventory_cost_of_sales;
drop view if exists public.v_inventory_valuation_layers;

drop function if exists public.fn_inventory_seed_opening_layers(uuid, boolean);
drop function if exists public.fn_inventory_last_invoiced_cost(uuid, uuid);

commit;
