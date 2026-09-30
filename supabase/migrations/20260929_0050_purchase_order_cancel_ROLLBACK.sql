-- ROLLBACK de 20260929_0050_purchase_order_cancel.sql
--
-- Solo quita la FUNCION. Se quedan a proposito:
--   - las columnas cancelled_at / cancelled_by / cancel_reason de
--     purchase_orders y la columna action de purchase_order_edits: guardan
--     quien anulo que y por que; borrarlas pierde esa auditoria.
--   - el permiso compras.ordenes.anular: existe desde 20260308_0022.
-- Las compras ya anuladas SIGUEN anuladas y sus movimientos de reversa se
-- quedan en el kardex: deshacerlos aqui descuadraria el stock.

begin;

drop function if exists public.fn_purchase_order_cancel(uuid, text, text, boolean);

commit;
