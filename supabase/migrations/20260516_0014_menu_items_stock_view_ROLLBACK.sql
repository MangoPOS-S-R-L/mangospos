-- Rollback de `20260516_0014_menu_items_stock_view.sql`.
-- Sin riesgo: la vista no tiene data propia.
begin;
drop view if exists public.v_menu_items_stock;
commit;
