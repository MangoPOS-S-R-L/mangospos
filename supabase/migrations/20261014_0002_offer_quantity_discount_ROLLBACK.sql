-- No reescribe ventas ni quita los snapshots ya guardados en las notas.
begin;
set local lock_timeout = '5s';
drop trigger if exists a00_offer_quantity_discount on public.order_items;
drop function if exists public.fn_offer_quantity_discount();
notify pgrst, 'reload schema';
commit;
