-- Rollback de `20260516_0016_reorder_suggestions.sql`.
-- Sin riesgo: la vista no tiene data propia.
begin;
drop view if exists public.v_inventory_reorder_suggestions;
commit;
