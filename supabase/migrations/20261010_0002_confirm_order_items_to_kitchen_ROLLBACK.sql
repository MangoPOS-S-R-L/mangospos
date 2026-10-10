-- Reversa de 20261010_0002. La app vuelve sola a fn_confirm_order_to_kitchen
-- (orden entera) al recibir PGRST202.
begin;
drop function if exists public.fn_confirm_order_items_to_kitchen(uuid, uuid[]);
commit;
