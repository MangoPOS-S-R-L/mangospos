-- =============================================================================
-- RLS que respeta el sistema de permisos de la app.
--
-- PROBLEMA:
--   La app reparte permisos granulares por rol (tablas `permissions`,
--   `role_permissions`, `employee_roles`, `employees`) y muestra los botones
--   según eso. Pero el RLS de varias tablas de configuración solo entiende
--   `is_admin_of_business`, es decir owner/admin. Resultado:
--
--     - Crear impresora con un cajero autorizado → 42501 (violates RLS).
--     - Borrar/editar un insumo con un rol no-admin → NO da error: la policy
--       filtra la fila y el DELETE afecta 0 registros. PostgREST responde
--       200 y la pantalla reporta un borrado que nunca ocurrió.
--
--   El segundo caso es el peligroso: falla en silencio.
--
-- SOLUCIÓN:
--   `user_has_business_permission(business, codigo)` traduce el modelo de
--   permisos de la app a algo que RLS puede consultar, y se agrega como
--   policy ADITIVA en las tablas afectadas.
--
-- ESTAS POLICIES SOLO AMPLÍAN:
--   En Postgres las policies permisivas se combinan con OR, así que las
--   existentes (`ii_admin`, `insert printers admins`, etc.) siguen intactas
--   y ningún owner/admin pierde acceso. Lo único que cambia es que ahora
--   TAMBIÉN pasa quien tenga el permiso concedido en su rol.
--
-- REQUISITO OPERATIVO:
--   No basta con esta migración: el permiso debe estar concedido al rol en
--   Configuración → Usuarios → Roles y Permisos. La función lee
--   `role_permissions.allow`.
--
-- IDEMPOTENTE: create or replace + drop policy if exists.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Puente permisos-de-app → RLS
--
-- SECURITY DEFINER a propósito: la función consulta `employees` y compañía,
-- que tienen sus propias policies. Sin definer, evaluarlas desde dentro de
-- una policy puede recursar. Mismo patrón que `current_user_business_ids`.
-- ---------------------------------------------------------------------------

create or replace function public.user_has_business_permission(
  p_business uuid,
  p_permission_code text
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.employees e
    join public.employee_roles er on er.employee_id = e.id
    join public.role_permissions rp on rp.role_id = er.role_id
    join public.permissions p on p.id = rp.permission_id
    where e.user_id = auth.uid()
      and e.business_id = p_business
      and coalesce(e.status, 'active') = 'active'
      and p.code = p_permission_code
      and coalesce(rp.allow, true)
  );
$$;

comment on function public.user_has_business_permission(uuid, text) is
  'True si el usuario actual tiene concedido el permiso granular de la app '
  '(role_permissions.allow) en ese negocio. Puente para usar en policies RLS.';

grant execute on function public.user_has_business_permission(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 2. inventory_items — crear / editar / borrar insumos
-- ---------------------------------------------------------------------------

drop policy if exists "ii_write_by_permission" on public.inventory_items;
create policy "ii_write_by_permission" on public.inventory_items
  for all to authenticated
  using (
    public.user_has_business_permission(
      business_id, 'inventario.productos.crear_editar')
  )
  with check (
    public.user_has_business_permission(
      business_id, 'inventario.productos.crear_editar')
  );

-- ---------------------------------------------------------------------------
-- 3. printers / print_areas / print_area_printers — configurar impresión
--
-- Las tres van juntas: dar de alta una impresora y asignarle áreas toca las
-- tres tablas, así que arreglar solo `printers` movería el error a la
-- siguiente pantalla.
-- ---------------------------------------------------------------------------

drop policy if exists "printers_write_by_permission" on public.printers;
create policy "printers_write_by_permission" on public.printers
  for all to authenticated
  using (
    public.user_has_business_permission(
      business_id, 'settings.impresoras.gestionar')
  )
  with check (
    public.user_has_business_permission(
      business_id, 'settings.impresoras.gestionar')
  );

drop policy if exists "print_areas_write_by_permission" on public.print_areas;
create policy "print_areas_write_by_permission" on public.print_areas
  for all to authenticated
  using (
    public.user_has_business_permission(
      business_id, 'settings.impresoras.gestionar')
  )
  with check (
    public.user_has_business_permission(
      business_id, 'settings.impresoras.gestionar')
  );

drop policy if exists "print_area_printers_write_by_permission"
  on public.print_area_printers;
create policy "print_area_printers_write_by_permission"
  on public.print_area_printers
  for all to authenticated
  using (
    public.user_has_business_permission(
      business_id, 'settings.impresoras.gestionar')
  )
  with check (
    public.user_has_business_permission(
      business_id, 'settings.impresoras.gestionar')
  );

commit;

-- ---------------------------------------------------------------------------
-- VERIFICACIÓN (correr aparte, cambiando el correo):
--
--   select e.business_id, b.business_name, r.name as rol, p.code, rp.allow
--   from public.employees e
--   join public.businesses b        on b.id  = e.business_id
--   join public.employee_roles er   on er.employee_id  = e.id
--   join public.roles r             on r.id  = er.role_id
--   join public.role_permissions rp on rp.role_id = r.id
--   join public.permissions p       on p.id  = rp.permission_id
--   where e.user_id = (select id from auth.users where email = 'CORREO')
--     and p.code in ('settings.impresoras.gestionar',
--                    'inventario.productos.crear_editar')
--   order by b.business_name, p.code;
--
-- Si no devuelve filas, el permiso NO está concedido a ese rol y la policy
-- nueva tampoco lo dejará pasar — hay que darlo en Roles y Permisos.
-- ---------------------------------------------------------------------------
