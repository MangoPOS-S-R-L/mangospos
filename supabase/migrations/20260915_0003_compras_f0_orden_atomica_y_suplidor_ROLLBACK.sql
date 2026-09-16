-- =============================================================================
-- ROLLBACK de 20260915_0003_compras_f0_orden_atomica_y_suplidor
--
-- Quita las dos funciones y la llave de idempotencia. NO quita las columnas
-- aseguradas (invoice_number, discount, ncf, purchase_unit, pack_size,
-- preferred_supplier_id): pertenecen a sus migraciones de origen y pueden
-- tener datos. La app vuelve sola al camino anterior (inserts directos) cuando
-- la función no existe.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

drop function if exists public.fn_purchase_resolve_suppliers(uuid, uuid[]);
drop function if exists public.fn_purchase_order_create(uuid, uuid, uuid, jsonb, text, date, jsonb, text);

drop index if exists public.idx_purchase_orders_idempotency;
alter table public.purchase_orders drop column if exists idempotency_key;

commit;

notify pgrst, 'reload schema';
