-- =============================================================================
-- ROLLBACK de 20260915_0009_compras_f5_presentaciones
--
-- BORRA la tabla de presentaciones (las presentaciones anidadas cargadas se
-- pierden). La presentación de compra ya aplanada en
-- inventory_items.purchase_unit / pack_size SE QUEDA: compras y recepción
-- siguen igual que antes de la migración.
-- =============================================================================

begin;

set local lock_timeout = '5s';

drop function if exists public.fn_inventory_item_presentations_save(uuid, jsonb);
drop table if exists public.inventory_item_presentations;
drop function if exists public.fn_inventory_item_presentations_guard();

commit;

notify pgrst, 'reload schema';
