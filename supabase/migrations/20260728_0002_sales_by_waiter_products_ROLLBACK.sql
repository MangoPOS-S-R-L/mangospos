-- Rollback de 20260728_0002: elimina la RPC del desglose de productos
-- por mesero.

begin;

drop function if exists public.fn_sales_by_waiter_products(uuid, date, date, text);

commit;
