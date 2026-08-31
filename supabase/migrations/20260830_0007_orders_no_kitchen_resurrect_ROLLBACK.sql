-- =====================================================================
-- ROLLBACK de 20260830_0007_orders_no_kitchen_resurrect.sql
-- Quita el trigger y su funcion. No toca nada mas — la migracion no
-- modifico ninguna funcion existente.
-- OJO: volver aqui reabre el bug de las ordenes que se quedan atascadas
-- en 'sent_to_kitchen' despues de cobradas.
-- =====================================================================

begin;

drop trigger if exists trg_orders_no_kitchen_resurrect on public.orders;
drop function if exists public.fn_orders_no_kitchen_resurrect();

commit;
