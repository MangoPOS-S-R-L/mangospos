-- ROLLBACK de 20260902_0005_new_item_joins_open_counts.sql
--
-- Quita los dos triggers y la función. Las líneas que ya se agregaron a un
-- conteo se quedan: son parte de la sesión, no metadata.
--
-- Sin esto, un insumo creado durante un conteo vuelve a quedar fuera de la
-- sesión; se puede sumar a mano desde la pantalla ("Agregar" o escaneando el
-- código, que es lo que usa fn_physical_count_add_item).

begin;

drop trigger if exists trg_inventory_items_join_open_counts
  on public.inventory_items;
drop trigger if exists trg_inventory_items_reactivated_join_open_counts
  on public.inventory_items;
drop function if exists public.fn_inventory_item_join_open_counts();

commit;
