-- ROLLBACK de 20260907_0004_modifier_sold_out.sql
--
-- Quita el auto-86 de modificadores. Las opciones vuelven a venderse siempre,
-- haya o no existencia. No toca `is_active` (el auto-86 de modificadores
-- nunca lo escribió).

begin;

drop trigger if exists trg_movements_recompute_modifier_availability
  on public.inventory_movements;

drop function if exists public.fn_trigger_recompute_modifier_availability();
drop function if exists public.fn_recompute_modifiers_availability(uuid);
drop function if exists public.fn_recompute_modifier_availability(uuid);

alter table public.modifiers drop column if exists is_sold_out;

commit;
