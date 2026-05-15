-- Rollback de `20260516_0002_sales_by_waiter.sql`.
-- Solo borra la RPC; no afecta datos.

begin;
drop function if exists public.fn_sales_by_waiter(uuid, date, date);
commit;
