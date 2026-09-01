-- ROLLBACK de 20260901_0002_resolve_consumption_warehouse.sql
--
-- Seguro mientras 20260901_0003_consume_by_area NO esté aplicada: si lo
-- está, `consume_inventory_from_order` llama a esta función y borrarla
-- rompería el descuento de inventario al vender. Revertir 0003 PRIMERO.

begin;

drop function if exists public.fn_resolve_consumption_warehouse(uuid, uuid, uuid);

commit;
