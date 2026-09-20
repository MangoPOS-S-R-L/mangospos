-- ROLLBACK de 20260919_0002 — quita el registro de productos quitados de la
-- cuenta y el reporte de comandas desaparecidas.
-- OJO: borra la tabla order_item_removals con todo lo registrado.

begin;

drop trigger if exists trg_zz_log_order_item_delete on public.order_items;
drop trigger if exists trg_zz_log_order_item_reduction on public.order_items;
drop function if exists public.fn_log_order_item_removal();
drop function if exists public.fn_note_order_item_removal(uuid, text, uuid);
drop function if exists public.fn_kitchen_missing_report(uuid, timestamptz, timestamptz);
drop table if exists public.order_item_removals;

notify pgrst, 'reload schema';

commit;
