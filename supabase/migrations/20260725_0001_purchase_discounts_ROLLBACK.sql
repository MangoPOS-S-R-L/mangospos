-- Rollback de 20260725_0001_purchase_discounts.sql
-- Elimina las columnas de descuento (se pierde el dato capturado).

begin;

alter table public.purchase_orders drop column if exists discount;
alter table public.purchase_order_items drop column if exists discount;

commit;
