-- ROLLBACK de 20260902_0006_order_items_product_fk.sql
--
-- Devuelve la regla a ON DELETE SET NULL, como la dejó 20260407_0001. Con eso
-- vuelve a ser posible borrar un producto con ventas y dejar el histórico sin
-- producto asociado.
--
-- El índice se conserva: no molesta y ayuda a cualquier consulta por producto.

alter table public.order_items
  drop constraint order_items_product_id_fkey,
  add  constraint order_items_product_id_fkey
       foreign key (product_id) references public.menu_items(id)
       on delete set null;
