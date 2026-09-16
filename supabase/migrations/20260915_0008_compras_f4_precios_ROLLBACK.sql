-- =============================================================================
-- ROLLBACK de 20260915_0008_compras_f4_precios
--
-- Quita el comparador y los triggers: recibir y anular dejan de actualizar
-- precios. Las columnas last_price_at / last_price_source y los precios y
-- vínculos que ya se aprendieron SE QUEDAN (son datos; borrarlos no devuelve
-- nada al estado anterior y la app vieja las ignora).
--
-- OJO: quitar el trigger de inventory_movements toma un candado breve.
-- =============================================================================

begin;

set local lock_timeout = '5s';

drop trigger if exists trg_inventory_movements_learn_supplier_price on public.inventory_movements;
drop function if exists public.fn_supplier_items_learn_from_receipt();

drop trigger if exists trg_direct_receipts_relearn_supplier_price on public.direct_receipts;
drop trigger if exists trg_purchase_receptions_relearn_supplier_price on public.purchase_receptions;
drop trigger if exists trg_purchase_orders_relearn_supplier_price on public.purchase_orders;
drop function if exists public.fn_supplier_items_relearn_on_cancel();
drop function if exists public.fn_supplier_items_relearn(uuid, uuid, uuid[]);

drop trigger if exists trg_supplier_items_price_stamp on public.supplier_items;
drop function if exists public.fn_supplier_items_price_stamp();

drop function if exists public.fn_purchase_price_comparison(uuid, uuid[], integer);

commit;

notify pgrst, 'reload schema';
