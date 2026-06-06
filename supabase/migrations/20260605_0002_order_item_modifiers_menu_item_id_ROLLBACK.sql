-- =============================================================================
-- ROLLBACK de 20260605_0002 — quita order_item_modifiers.menu_item_id
-- =============================================================================
-- Aplicar SOLO después de revertir 20260605_0003 (consume_inventory por combo),
-- que depende de esta columna.
-- =============================================================================

begin;

drop index if exists public.idx_order_item_modifiers_menu_item_id;

alter table public.order_item_modifiers
  drop constraint if exists order_item_modifiers_menu_item_id_fkey;

alter table public.order_item_modifiers
  drop column if exists menu_item_id;

commit;
