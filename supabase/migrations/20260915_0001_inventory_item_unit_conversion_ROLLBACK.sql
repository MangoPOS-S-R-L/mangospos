-- =============================================================================
-- ROLLBACK de 20260915_0001_inventory_item_unit_conversion
--
-- OJO: borra las equivalencias cargadas (1 unidad = N g). Las recetas ya
-- guardadas NO cambian: quedaron escritas en la unidad base del insumo.
--
-- Si después de aplicar la migración se creó una vista que nombra estas
-- columnas, el DROP COLUMN falla: hay que quitar esa vista primero.
-- =============================================================================

begin;

alter table public.inventory_items
  drop constraint if exists inventory_items_conversion_pair_check;

alter table public.inventory_items
  drop constraint if exists inventory_items_conversion_factor_check;

alter table public.inventory_items
  drop column if exists conversion_factor;

alter table public.inventory_items
  drop column if exists conversion_unit;

commit;

notify pgrst, 'reload schema';
