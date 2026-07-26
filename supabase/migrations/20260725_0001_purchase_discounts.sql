-- =============================================================================
-- Compras: descuentos del proveedor.
--
-- El registro de compra ahora permite capturar descuentos que el proveedor
-- otorga en su factura, en dos niveles:
--
--   1. `purchase_order_items.discount` — descuento de la LÍNEA, en RD$ NETO
--      (sin ITBIS). Informativo/auditoría: `unit_cost` se guarda YA descontado
--      (costo real pagado), así el kardex (`fn_receive_purchase_order` postea
--      `unit_cost` tal cual) y el costo maestro quedan correctos sin cambios
--      de servidor. El precio original se reconstruye:
--        precio_neto_original = (quantity_ordered * unit_cost + discount) / quantity_ordered
--
--   2. `purchase_orders.discount` — descuento GLOBAL de la orden, en RD$.
--      Es financiero (pronto pago, acuerdo comercial): NO se prorratea a las
--      líneas ni afecta costos/kardex. total = subtotal + tax - discount.
--
-- ADITIVA e idempotente: solo agrega columnas con default 0; ningún flujo
-- existente cambia (las órdenes viejas quedan con discount = 0).
-- =============================================================================

begin;

alter table public.purchase_orders
  add column if not exists discount numeric not null default 0;

alter table public.purchase_order_items
  add column if not exists discount numeric not null default 0;

comment on column public.purchase_orders.discount is
  'Descuento global de la orden en RD$ (no prorrateado a líneas). '
  'total = subtotal + tax - discount.';

comment on column public.purchase_order_items.discount is
  'Descuento de la línea en RD$ NETO (sin ITBIS), informativo: unit_cost '
  'ya viene descontado (costo real). Original = (qty*unit_cost + discount)/qty.';

commit;
