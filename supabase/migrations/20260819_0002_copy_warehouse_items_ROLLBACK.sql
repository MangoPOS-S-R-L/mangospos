-- ROLLBACK de 20260819_0002_copy_warehouse_items.sql
--
-- Sólo quita la función. Las filas de `inventory_stock` que haya creado se
-- quedan: son insumos en cero de una bodega real y borrarlos a ciegas
-- eliminaría también los que después recibieron mínimos o movimientos.

begin;

drop function if exists
  public.fn_inventory_copy_warehouse_items(uuid, uuid, boolean);

commit;
