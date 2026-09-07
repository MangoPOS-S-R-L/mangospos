-- ROLLBACK de 20260907_0002_order_item_modifiers_modifier_id.sql
--
-- Aplicar ANTES el rollback de 20260907_0003 (el consumo lee esta columna).

begin;

drop index if exists public.idx_order_item_modifiers_modifier_id;

alter table public.order_item_modifiers
  drop constraint if exists order_item_modifiers_modifier_id_fkey;

alter table public.order_item_modifiers
  drop column if exists modifier_id;

commit;
