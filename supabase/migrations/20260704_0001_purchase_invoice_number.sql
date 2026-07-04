-- 20260704_0001_purchase_invoice_number.sql
-- Scope:
--   Guarda el número de factura del proveedor en la orden de compra.
--   Antes solo existía `order_number` (folio interno PO-xxxxx). El registro
--   de compra ahora captura, además, el NCF/número de factura físico que trae
--   el documento del proveedor (ej. B0100000284 / FACT 1123) para conciliación.
--
-- Notas:
--   - Columna NULLABLE y aditiva: no rompe órdenes existentes ni otros callers
--     (inventory_reorder crea OCs sin factura).
--   - El impuesto por línea sigue viviendo en purchase_order_items.tax_rate
--     (con ITBIS = 18, sin ITBIS = 0); no requiere cambio de esquema.

begin;

alter table public.purchase_orders
  add column if not exists invoice_number text;

comment on column public.purchase_orders.invoice_number is
  'Número de factura/NCF físico del proveedor (distinto del folio interno order_number).';

commit;
