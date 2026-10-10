-- Reversa de 20261010_0006. La app nueva deja de poder editar cuentas
-- (fn_apply_order_edit no existe: PGRST202 → «Falta actualizar el servidor»);
-- no recurre a las funciones sin versión.
begin;
drop function if exists public.fn_apply_order_edit(uuid, uuid, text, uuid, bigint, jsonb, jsonb, boolean);
drop function if exists public.fn_append_session_note(uuid, text);
drop table if exists public.order_edit_ops;
drop trigger if exists trg_zz_order_item_version_modifiers on public.order_item_modifiers;
drop trigger if exists trg_aa_order_version on public.orders;
drop trigger if exists trg_aa_order_item_version on public.order_items;
drop function if exists public.trg_order_item_version_from_modifiers();
drop function if exists public.trg_order_version();
drop function if exists public.trg_order_item_version();
alter table public.order_items drop column if exists version;
alter table public.orders drop column if exists version;
commit;
