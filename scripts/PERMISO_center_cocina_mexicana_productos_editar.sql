-- =============================================================================
-- LA COCINA MEXICANA AUTENTICA — «Center» (ficha «Agora», Supervisor) no puede
-- guardar en Modificadores (42501 en menu_item_groups).
--
-- Diagnóstico 2026-10-13: su rol `manager` (24604dd0) NO tiene productos.editar;
-- la app se lo da por un permiso individual (user_permission_overrides), que el
-- puente RLS user_has_business_permission no lee. Center es la ÚNICA persona con
-- ese rol (1 ficha, 1 login), así que concederlo al rol solo lo afecta a él.
--
-- Requiere además 20261013_0003_modifiers_rls_honor_app_permissions.sql.
-- Pegar TODO en el SQL Editor: el último resultado es la verificación.
-- =============================================================================

begin;

-- Candado: el rol tiene que ser `manager` de ESTE negocio; si no, no inserta nada.
insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
join public.businesses b on b.id = r.business_id
cross join public.permissions p
where r.id = '24604dd0-9f6f-4348-89e1-75187468eb91'
  and r.name = 'manager'
  and b.business_name = 'LA COCINA MEXICANA AUTENTICA'
  and p.code = 'productos.editar'
on conflict (role_id, permission_id) do nothing;

commit;

-- Verificación (esperado: rls_pasa = true, policies_0003 = 12).
select
  coalesce(pr.full_name, ub.user_id::text)            as usuario,
  exists (
    select 1
    from public.employee_roles er
    join public.role_permissions rp on rp.role_id = er.role_id
    join public.permissions p on p.id = rp.permission_id
    where er.employee_id = e.id
      and coalesce(e.status, 'active') = 'active'
      and p.code = 'productos.editar'
      and coalesce(rp.allow, true)
  )                                                   as rls_pasa,
  (select count(*) from pg_policies
    where schemaname = 'public'
      and tablename in ('modifier_groups', 'modifiers', 'menu_item_groups',
                        'modifier_ingredients')
      and policyname like '%\_by\_permission')       as policies_0003
from public.user_businesses ub
join public.businesses b on b.id = ub.business_id
join public.profiles pr on pr.id = ub.user_id
left join public.employees e
  on e.user_id = ub.user_id and e.business_id = ub.business_id
where b.business_name = 'LA COCINA MEXICANA AUTENTICA'
  and pr.full_name = 'Center'
  and ub.role = 'manager';

-- -----------------------------------------------------------------------------
-- DESHACER (antes no había fila; borrar la que se creó):
--   delete from public.role_permissions
--   where role_id = '24604dd0-9f6f-4348-89e1-75187468eb91'
--     and permission_id = (select id from public.permissions
--                          where code = 'productos.editar');
-- -----------------------------------------------------------------------------
