-- Rollback manual de 20261009_0007. La app que la usa recurre al camino viejo
-- (leer la orden y después fn_close_order_and_table) cuando no la encuentra.
begin;
drop function if exists public.fn_void_order_if_unpaid(uuid);
commit;
