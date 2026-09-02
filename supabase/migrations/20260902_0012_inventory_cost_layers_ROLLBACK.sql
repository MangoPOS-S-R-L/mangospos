-- Rollback de 20260902_0012_inventory_cost_layers.sql
--
-- Apagar el motor NO requiere este rollback: basta con
--   update public.business_settings set inventory_costing_method = 'last_price';
-- que deja el trigger inerte y conserva las capas ya construidas.
--
-- Este archivo borra la infraestructura completa, capas incluidas.

begin;

drop trigger if exists trg_inventory_cost_layers on public.inventory_movements;
drop function if exists public.fn_inventory_cost_layers_apply();
drop function if exists public.fn_inventory_last_known_cost(uuid, uuid, uuid);

drop table if exists public.inventory_cost_consumptions;
drop table if exists public.inventory_cost_layers;

alter table public.business_settings
  drop constraint if exists business_settings_inventory_costing_method_check;
alter table public.business_settings
  drop column if exists inventory_costing_method;

commit;
