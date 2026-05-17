-- Rollback de `20260516_0012_inventory_items_missing_columns.sql`.
-- ⚠️ NO recomendado correr en producción si ya hay datos:
--   - `tracks_lots = true` en algunos items implica lotes registrados.
--   - `updated_at` lo consume el trigger.
--   - Borrar columnas pierde data sin recuperación.
--
-- Solo se documenta para tests / DBs vacías.

begin;
drop trigger if exists trg_inventory_items_touch on public.inventory_items;
drop function if exists public.fn_inventory_items_touch_updated_at();

alter table public.inventory_items drop column if exists updated_at;
alter table public.inventory_items drop column if exists tracks_lots;
alter table public.inventory_items drop column if exists barcode;

alter table public.inventory_items drop constraint if exists inventory_items_costing_method_check;
alter table public.inventory_items drop column if exists costing_method;
commit;
