-- Rollback de `20260521_0003_menu_item_print_areas.sql`.
--
-- Las asignaciones N:M se PIERDEN. Si el código nuevo (orchestrator) ya las
-- está usando, queda la asignación 1:1 vía `menu_items.print_area_code` como
-- fallback — los productos con múltiples áreas perderán la(s) extra(s).

begin;

drop policy if exists "menu_item_print_areas_write"  on public.menu_item_print_areas;
drop policy if exists "menu_item_print_areas_select" on public.menu_item_print_areas;

drop table if exists public.menu_item_print_areas;

commit;
