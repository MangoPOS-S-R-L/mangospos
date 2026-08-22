-- ROLLBACK de 20260819_0001_warehouse_min_stock.sql
--
-- OJO: al borrar la columna se pierden los mínimos por bodega que se hayan
-- configurado. La app degrada sola (vuelve a mostrar sólo el mínimo global),
-- así que no hace falta desplegar nada más.

begin;

drop function if exists
  public.fn_inventory_set_warehouse_min_stock(uuid, uuid, numeric);

drop index if exists public.idx_inventory_stock_warehouse_min_stock;

alter table public.inventory_stock
  drop column if exists min_stock;

commit;
