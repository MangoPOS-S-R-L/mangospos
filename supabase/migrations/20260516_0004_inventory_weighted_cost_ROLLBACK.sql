-- Rollback de `20260516_0004_inventory_weighted_cost.sql`.
-- Deja `inventory_items.cost` con los valores recalculados hasta ese
-- momento (no los revierte). Solo quita el trigger y las funciones.

begin;
drop trigger if exists trg_inventory_movement_recost on public.inventory_movements;
drop function if exists public.fn_inventory_movement_recost();
drop function if exists public.fn_recompute_item_cost_weighted_avg(uuid, numeric, numeric);
commit;
