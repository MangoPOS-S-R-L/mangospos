-- =============================================================================
-- ROLLBACK de 20260915_0005_compras_f2_ordenes_en_lote
-- Solo quita la función. Las órdenes que ya creó quedan (son órdenes normales).
-- La pantalla «Pedido sugerido» cae a crear orden por orden cuando no existe.
-- =============================================================================

begin;

set local lock_timeout = '5s';

drop function if exists public.fn_purchase_orders_create_batch(uuid, uuid, jsonb, text, text);

commit;

notify pgrst, 'reload schema';
