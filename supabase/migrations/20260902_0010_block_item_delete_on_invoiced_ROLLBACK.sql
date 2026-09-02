-- ROLLBACK de 20260902_0010_block_item_delete_on_invoiced.sql
--
-- OJO: quitarlo reabre H-3 — se vuelve a poder vaciar una mesa que ya tiene
-- NCF activo, y la factura queda cobrando mas de lo que hay registrado.

drop trigger if exists trg_block_item_delete_on_invoiced on public.order_items;
drop function if exists public.fn_block_item_delete_on_invoiced();
