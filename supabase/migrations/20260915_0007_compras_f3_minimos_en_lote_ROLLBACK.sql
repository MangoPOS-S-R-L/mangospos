-- =============================================================================
-- ROLLBACK de 20260915_0007_compras_f3_minimos_en_lote
-- Solo quita la función. Los mínimos que ya se guardaron se quedan (son los
-- mismos campos que se editan uno a uno desde Insumos y Bodegas).
-- =============================================================================

begin;

set local lock_timeout = '5s';

drop function if exists public.fn_inventory_set_min_stock_bulk(uuid, uuid, jsonb);

commit;

notify pgrst, 'reload schema';
