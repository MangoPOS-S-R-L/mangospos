-- Rollback de `20260516_0015_auto_86.sql`.
-- ⚠️ Deja productos en el estado actual:
--   - Los que fueron auto-86'd mantienen is_active = false. El admin debe
--     reactivarlos manualmente desde Productos.
--   - La columna auto_disabled se elimina (su info se pierde).
--
-- Después del rollback, ventas sin stock vuelven a permitirse sin alerta.

begin;
drop trigger if exists trg_movements_recompute_menu_availability
  on public.inventory_movements;
drop function if exists public.fn_trigger_recompute_menu_availability();
drop function if exists public.fn_recompute_menu_items_availability(uuid);
alter table public.menu_items drop column if exists auto_disabled;
commit;
