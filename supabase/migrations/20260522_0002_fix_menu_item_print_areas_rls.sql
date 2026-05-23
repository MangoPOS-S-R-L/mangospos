-- 20260522_0002_fix_menu_item_print_areas_rls.sql
-- Fix: RLS de menu_item_print_areas bloquea silenciosamente al owner.
--
-- Bug: la RLS original (migration 20260521_0003) hace JOIN con
-- `memberships.role in ('owner','admin','manager')`. Pero cuando se crea
-- un negocio vía `fn_create_branch_business` (migration 20260321_0034:93),
-- la fila de memberships se inserta SIN especificar `role`, así que toma
-- el default `'staff'::member_role`. Resultado:
--
--   - user_businesses.role = 'owner'   ✅ (este sí se setea correctamente)
--   - memberships.role     = 'staff'   ❌ (default no actualizado)
--
-- La RLS chequea memberships.role → 'staff' no está en
-- ('owner','admin','manager') → DENIED. Los INSERT/DELETE/UPDATE a
-- menu_item_print_areas no afectan filas (PostgREST devuelve 0 rows sin
-- error visible). Por eso el cajero "asigna área pero no se guarda".
--
-- Fix: re-emitir las policies usando el helper canónico
-- `user_business_role(uid, business_id)` que ya está en uso en categories,
-- menu_items, business_settings, inventory_items, etc. Ese helper consulta
-- user_businesses (que sí tiene el role correcto del owner).
--
-- Compatibilidad: re-ejecutable, drop policy if exists antes de create.
-- Rollback: vuelve a las policies originales con memberships.

begin;

-- ---------------------------------------------------------------------------
-- Reemplazar policies de menu_item_print_areas
-- ---------------------------------------------------------------------------

drop policy if exists "menu_item_print_areas_select" on public.menu_item_print_areas;
drop policy if exists "menu_item_print_areas_write"  on public.menu_item_print_areas;

-- SELECT: cualquier miembro del business del menu_item puede leer las
-- asignaciones de áreas (necesario para el dialog de edición de producto
-- que las recarga al abrir).
create policy "menu_item_print_areas_select"
  on public.menu_item_print_areas
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.menu_items mi
      where mi.id = menu_item_print_areas.menu_item_id
        and public.user_business_role(auth.uid(), mi.business_id) is not null
    )
  );

-- WRITE (INSERT/UPDATE/DELETE): solo owner/admin/manager del business.
create policy "menu_item_print_areas_write"
  on public.menu_item_print_areas
  for all
  to authenticated
  using (
    exists (
      select 1
      from public.menu_items mi
      where mi.id = menu_item_print_areas.menu_item_id
        and public.user_business_role(auth.uid(), mi.business_id) = any (
          array['owner', 'admin', 'manager']
        )
    )
  )
  with check (
    exists (
      select 1
      from public.menu_items mi
      where mi.id = menu_item_print_areas.menu_item_id
        and public.user_business_role(auth.uid(), mi.business_id) = any (
          array['owner', 'admin', 'manager']
        )
    )
  );

commit;
