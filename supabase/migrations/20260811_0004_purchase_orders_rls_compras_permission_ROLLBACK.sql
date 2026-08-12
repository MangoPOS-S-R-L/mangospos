-- Rollback de 20260811_0004_purchase_orders_rls_compras_permission.sql
-- Las policies base po_write/poi_write (owner/admin) quedan intactas.

begin;

drop policy if exists "po_write_compras" on public.purchase_orders;
drop policy if exists "poi_write_compras" on public.purchase_order_items;

commit;
