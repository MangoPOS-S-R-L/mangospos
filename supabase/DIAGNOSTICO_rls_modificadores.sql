-- =============================================================================
-- Modificadores: ¿por qué el Supervisor no puede asignar productos? (42501)
-- Solo lectura. Correr ANTES y DESPUÉS de 20261013_0003.
-- El SQL Editor muestra solo el último resultado: correr cada consulta SOLA.
-- =============================================================================

-- 1) Policies vivas en las tablas de la pantalla de Modificadores.
--    ANTES: solo *_read y *_write (owner/admin).
--    DESPUÉS: además mg_/mod_/mig_/mi_ing_{insert,update,delete}_by_permission.
select tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public'
  and tablename in ('modifier_groups', 'modifiers', 'menu_item_groups',
                    'modifier_ingredients')
order by tablename, policyname;

-- 2) Usuarios no-admin con acceso a la pantalla: ¿la policy nueva los dejará
--    pasar? `rls_pasa` replica user_has_business_permission (employees +
--    employee_roles + role_permissions); `app_permite` replica
--    fn_user_effective_permissions (user_roles + overrides), que es lo que la
--    app usa para abrirle la pantalla.
--    Fila con app_permite = true y rls_pasa = false → la migración NO basta:
--    falta fila en employees/employee_roles o el permiso en ese rol.
--    app_permite = false pero igual ve la pantalla → la app cayó al preset
--    local (negocio sin RBAC sembrado); el RLS tampoco lo dejará pasar.
with perm as (
  select id from public.permissions where code = 'productos.editar'
),
miembros as (
  select ub.business_id, ub.user_id, ub.role as rol_membresia
  from public.user_businesses ub
  where ub.role not in ('owner', 'admin')
)
select
  b.business_name                                as negocio,
  coalesce(p.full_name, u.email)                 as usuario,
  m.rol_membresia,
  e.id is not null                               as tiene_employee,
  e.status                                       as employee_status,
  (select string_agg(r.name, ', ')
     from public.employee_roles er
     join public.roles r on r.id = er.role_id
    where er.employee_id = e.id)                 as roles_employee,
  exists (
    select 1
    from public.employee_roles er
    join public.role_permissions rp on rp.role_id = er.role_id
    where er.employee_id = e.id
      and coalesce(e.status, 'active') = 'active'
      and rp.permission_id = (select id from perm)
      and coalesce(rp.allow, true)
  )                                              as rls_pasa,
  coalesce(
    (select o.allow
       from public.user_permission_overrides o
      where o.user_id = m.user_id
        and o.business_id = m.business_id
        and o.permission_id = (select id from perm)),
    (select bool_or(rp.allow)
       from public.user_roles ur
       join public.role_permissions rp on rp.role_id = ur.role_id
      where ur.user_id = m.user_id
        and ur.business_id = m.business_id
        and rp.permission_id = (select id from perm)),
    false
  )                                              as app_permite
from miembros m
join public.businesses b on b.id = m.business_id
left join auth.users u on u.id = m.user_id
left join public.profiles p on p.id = m.user_id
left join public.employees e
  on e.user_id = m.user_id and e.business_id = m.business_id
order by b.business_name, m.rol_membresia, usuario;
