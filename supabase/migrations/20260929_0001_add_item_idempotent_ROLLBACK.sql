-- ROLLBACK de 20260929_0001_add_item_idempotent.sql
-- La app nueva bloquea altas si se retira esta función; coordinar rollback
-- del cliente para evitar detener ventas.
begin;

drop function if exists public.fn_add_item_from_menu_idempotent(
  uuid, uuid, uuid, numeric, integer, boolean, text, uuid
);
drop function if exists public.fn_add_offer_deal_idempotent(
  uuid, uuid, uuid, numeric, numeric, text, uuid, integer, uuid
);
drop function if exists public.fn_replace_order_item_modifiers(uuid, jsonb);
drop table if exists public.order_item_client_ops;

commit;

notify pgrst, 'reload schema';
