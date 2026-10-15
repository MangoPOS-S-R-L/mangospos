-- =============================================================================
-- 20261013_0003 — Modificadores: escritura para quien tenga `productos.editar`
--
-- PROBLEMA (reportado en tablet, usuario con rol Supervisor):
--   Modificadores → Asignación a productos → Guardar:
--     42501 new row violates row-level security policy for table
--     "menu_item_groups"
--
--   La app le concede al Supervisor (manager) productos.crear/editar/eliminar
--   y le abre la pantalla, pero el RLS de las cuatro tablas que esa pantalla
--   escribe solo deja pasar a owner/admin:
--     menu_item_groups_write · modifier_groups_write · modifiers_write ·
--     mi_ing_write
--
--   Lo visible es el INSERT que revienta. Lo peligroso es lo que NO revienta:
--   editar o borrar un grupo/opción con ese rol filtra la fila, el UPDATE o
--   DELETE afecta 0 registros, PostgREST responde 200 y la pantalla lo da por
--   guardado. Mismo caso que documentó 20260803_0001.
--
-- SOLUCIÓN:
--   Patrón de 20260803_0001 y 20260811_0004: policies ADITIVAS vía el puente
--   `user_has_business_permission(business, 'productos.editar')`. Las policies
--   permisivas se combinan con OR, así que las existentes quedan intactas y
--   ningún owner/admin pierde acceso.
--
--   - Las cuatro tablas van juntas: abrir solo menu_item_groups movería el
--     error al siguiente botón (crear grupo, agregar opción, insumos).
--   - Separadas en INSERT/UPDATE/DELETE, sin FOR ALL: así no se suman a la
--     lectura, que es camino caliente (toma de pedidos, sync offline).
--   - El WITH CHECK exige que las dos puntas sean del MISMO negocio (producto
--     y grupo; grupo y opción; opción e insumo), igual que mi_ing_write, para
--     que no se cuele un id de otro tenant.
--
-- REQUISITO OPERATIVO:
--   El rol del usuario debe tener `productos.editar` concedido en
--   Configuración → Usuarios → Roles y Permisos (role_permissions.allow), y el
--   usuario debe tener fila en employees + employee_roles. Correr antes
--   supabase/DIAGNOSTICO_rls_modificadores.sql.
--
-- IDEMPOTENTE: drop policy if exists + create policy.
-- Rollback: 20261013_0003_modifiers_rls_honor_app_permissions_ROLLBACK.sql
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. modifier_groups — crear / editar / borrar grupos
-- ---------------------------------------------------------------------------

drop policy if exists "mg_insert_by_permission" on public.modifier_groups;
create policy "mg_insert_by_permission" on public.modifier_groups
  for insert to authenticated
  with check (
    public.user_has_business_permission(business_id, 'productos.editar')
  );

drop policy if exists "mg_update_by_permission" on public.modifier_groups;
create policy "mg_update_by_permission" on public.modifier_groups
  for update to authenticated
  using (
    public.user_has_business_permission(business_id, 'productos.editar')
  )
  with check (
    public.user_has_business_permission(business_id, 'productos.editar')
  );

drop policy if exists "mg_delete_by_permission" on public.modifier_groups;
create policy "mg_delete_by_permission" on public.modifier_groups
  for delete to authenticated
  using (
    public.user_has_business_permission(business_id, 'productos.editar')
  );

-- ---------------------------------------------------------------------------
-- 2. modifiers — opciones del grupo (incluye reordenar: sort_order)
-- ---------------------------------------------------------------------------

drop policy if exists "mod_insert_by_permission" on public.modifiers;
create policy "mod_insert_by_permission" on public.modifiers
  for insert to authenticated
  with check (
    public.user_has_business_permission(business_id, 'productos.editar')
    and (
      group_id is null
      or exists (
        select 1 from public.modifier_groups g
        where g.id = modifiers.group_id
          and g.business_id = modifiers.business_id
      )
    )
  );

drop policy if exists "mod_update_by_permission" on public.modifiers;
create policy "mod_update_by_permission" on public.modifiers
  for update to authenticated
  using (
    public.user_has_business_permission(business_id, 'productos.editar')
  )
  with check (
    public.user_has_business_permission(business_id, 'productos.editar')
    and (
      group_id is null
      or exists (
        select 1 from public.modifier_groups g
        where g.id = modifiers.group_id
          and g.business_id = modifiers.business_id
      )
    )
  );

drop policy if exists "mod_delete_by_permission" on public.modifiers;
create policy "mod_delete_by_permission" on public.modifiers
  for delete to authenticated
  using (
    public.user_has_business_permission(business_id, 'productos.editar')
  );

-- ---------------------------------------------------------------------------
-- 3. menu_item_groups — asignar grupos a productos (el error de la foto)
--
-- "Guardar" en Asignación hace DELETE por group_id + INSERT, así que hacen
-- falta las dos. UPDATE cubre el orden por producto (position).
-- ---------------------------------------------------------------------------

drop policy if exists "mig_insert_by_permission" on public.menu_item_groups;
create policy "mig_insert_by_permission" on public.menu_item_groups
  for insert to authenticated
  with check (
    exists (
      select 1
      from public.menu_items mi
      join public.modifier_groups g on g.id = menu_item_groups.group_id
      where mi.id = menu_item_groups.menu_item_id
        and g.business_id = mi.business_id
        and public.user_has_business_permission(
              mi.business_id, 'productos.editar')
    )
  );

drop policy if exists "mig_update_by_permission" on public.menu_item_groups;
create policy "mig_update_by_permission" on public.menu_item_groups
  for update to authenticated
  using (
    exists (
      select 1 from public.menu_items mi
      where mi.id = menu_item_groups.menu_item_id
        and public.user_has_business_permission(
              mi.business_id, 'productos.editar')
    )
  )
  with check (
    exists (
      select 1
      from public.menu_items mi
      join public.modifier_groups g on g.id = menu_item_groups.group_id
      where mi.id = menu_item_groups.menu_item_id
        and g.business_id = mi.business_id
        and public.user_has_business_permission(
              mi.business_id, 'productos.editar')
    )
  );

drop policy if exists "mig_delete_by_permission" on public.menu_item_groups;
create policy "mig_delete_by_permission" on public.menu_item_groups
  for delete to authenticated
  using (
    exists (
      select 1 from public.menu_items mi
      where mi.id = menu_item_groups.menu_item_id
        and public.user_has_business_permission(
              mi.business_id, 'productos.editar')
    )
  );

-- ---------------------------------------------------------------------------
-- 4. modifier_ingredients — insumos que descuenta la opción
-- ---------------------------------------------------------------------------

drop policy if exists "mi_ing_insert_by_permission" on public.modifier_ingredients;
create policy "mi_ing_insert_by_permission" on public.modifier_ingredients
  for insert to authenticated
  with check (
    exists (
      select 1
      from public.modifiers m
      join public.inventory_items ii
        on ii.id = modifier_ingredients.inventory_item_id
      where m.id = modifier_ingredients.modifier_id
        and ii.business_id = m.business_id
        and public.user_has_business_permission(
              m.business_id, 'productos.editar')
    )
  );

drop policy if exists "mi_ing_update_by_permission" on public.modifier_ingredients;
create policy "mi_ing_update_by_permission" on public.modifier_ingredients
  for update to authenticated
  using (
    exists (
      select 1 from public.modifiers m
      where m.id = modifier_ingredients.modifier_id
        and public.user_has_business_permission(
              m.business_id, 'productos.editar')
    )
  )
  with check (
    exists (
      select 1
      from public.modifiers m
      join public.inventory_items ii
        on ii.id = modifier_ingredients.inventory_item_id
      where m.id = modifier_ingredients.modifier_id
        and ii.business_id = m.business_id
        and public.user_has_business_permission(
              m.business_id, 'productos.editar')
    )
  );

drop policy if exists "mi_ing_delete_by_permission" on public.modifier_ingredients;
create policy "mi_ing_delete_by_permission" on public.modifier_ingredients
  for delete to authenticated
  using (
    exists (
      select 1 from public.modifiers m
      where m.id = modifier_ingredients.modifier_id
        and public.user_has_business_permission(
              m.business_id, 'productos.editar')
    )
  );

commit;
