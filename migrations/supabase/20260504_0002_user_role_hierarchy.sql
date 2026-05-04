-- Blinda la asignación de roles con validación de jerarquía:
-- nadie puede crear/editar un usuario asignándole un rol con jerarquía
-- mayor o igual a la suya (excepto owner, que es el techo y puede asignar
-- cualquier rol, incluyendo otro owner).
--
-- Jerarquía:
--   owner    = 4
--   admin    = 3
--   manager  = 2
--   cashier/waiter/cook/delivery = 1
--
-- Reglas resultantes:
--   - owner  puede asignar: owner, admin, manager, operativos
--   - admin  puede asignar: manager, operativos        (NO admin ni owner)
--   - manager puede asignar: operativos                 (NO manager ni admin/owner)
--   - operativos: no pueden asignar nada (RPC los rechaza)
--
-- También alinea los permisos de gestión de usuarios entre el catálogo Dart
-- y la BD: ahora manager tiene crear/editar/desactivar usuarios en BD.

begin;

-- 1) Función auxiliar: jerarquía numérica de un nombre de rol.
create or replace function public.fn_role_hierarchy(p_role text)
returns int
language sql
immutable
as $$
  select case lower(coalesce(p_role, ''))
    when 'owner'    then 4
    when 'admin'    then 3
    when 'manager'  then 2
    when 'cashier'  then 1
    when 'waiter'   then 1
    when 'cook'     then 1
    when 'chef'     then 1
    when 'delivery' then 1
    else 0
  end
$$;

-- 2) Reemplazar fn_save_user_access_profile con validación de jerarquía.
create or replace function public.fn_save_user_access_profile(
  p_employee_id uuid,
  p_business_id uuid,
  p_role_ids uuid[],
  p_primary_role text,
  p_effective_permission_codes text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee public.employees;
  v_user_id uuid;
  v_normalized_role text;
  v_caller_role text;
  v_caller_rank int;
  v_target_rank int;
  v_max_role_rank int;
begin
  -- Caller debe ser owner, admin o manager.
  v_caller_role := public.user_business_role(auth.uid(), p_business_id);
  if v_caller_role not in ('owner', 'admin', 'manager') then
    raise exception 'ACCESS_DENIED';
  end if;

  v_caller_rank := public.fn_role_hierarchy(v_caller_role);

  -- Validar primary_role: no se puede asignar un rol >= al propio,
  -- salvo owner que puede asignar cualquier cosa (incluido owner).
  v_target_rank := public.fn_role_hierarchy(p_primary_role);
  if v_caller_role <> 'owner' and v_target_rank >= v_caller_rank then
    raise exception 'CANNOT_ASSIGN_ROLE_AT_OR_ABOVE_OWN_HIERARCHY'
      using errcode = '42501';
  end if;

  -- Validar todos los role_ids: ninguno puede tener jerarquía >= caller
  -- (salvo owner). Esto cubre el caso de p_role_ids con varios roles.
  if v_caller_role <> 'owner'
     and coalesce(array_length(p_role_ids, 1), 0) > 0 then
    select coalesce(max(public.fn_role_hierarchy(r.name)), 0)
      into v_max_role_rank
      from public.roles r
      where r.id = any(p_role_ids);

    if v_max_role_rank >= v_caller_rank then
      raise exception 'CANNOT_ASSIGN_ROLE_AT_OR_ABOVE_OWN_HIERARCHY'
        using errcode = '42501';
    end if;
  end if;

  select *
    into v_employee
  from public.employees
  where id = p_employee_id
    and business_id = p_business_id;

  if not found then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;

  v_user_id := v_employee.user_id;
  v_normalized_role := case
    when lower(coalesce(p_primary_role, '')) in ('owner','admin','manager','cashier','waiter','delivery') then lower(p_primary_role)
    when lower(coalesce(p_primary_role, '')) in ('cook','chef') then 'cook'
    else 'waiter'
  end;

  delete from public.employee_roles where employee_id = p_employee_id;

  if coalesce(array_length(p_role_ids, 1), 0) > 0 then
    insert into public.employee_roles (employee_id, role_id)
    select p_employee_id, role_id
    from unnest(p_role_ids) as role_id
    on conflict do nothing;
  end if;

  if v_user_id is null then
    return;
  end if;

  insert into public.user_businesses (user_id, business_id, role, permissions, created_at)
  values (
    v_user_id,
    p_business_id,
    v_normalized_role,
    case when v_normalized_role in ('owner', 'admin') then array['all']::text[] else array[]::text[] end,
    now()
  )
  on conflict (user_id, business_id) do update
    set role = excluded.role,
        permissions = excluded.permissions;

  delete from public.user_roles
  where user_id = v_user_id
    and business_id = p_business_id;

  if coalesce(array_length(p_role_ids, 1), 0) > 0 then
    insert into public.user_roles (user_id, role_id, business_id, created_by)
    select v_user_id, role_id, p_business_id, auth.uid()
    from unnest(p_role_ids) as role_id
    on conflict do nothing;
  end if;

  delete from public.user_permission_overrides
  where user_id = v_user_id
    and business_id = p_business_id;

  with base_codes as (
    select distinct p.code
    from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = any(coalesce(p_role_ids, array[]::uuid[]))
      and coalesce(rp.allow, true) = true
  ),
  desired_codes as (
    select distinct code
    from unnest(coalesce(p_effective_permission_codes, array[]::text[])) as code
  ),
  allow_extra as (
    select d.code
    from desired_codes d
    left join base_codes b on b.code = d.code
    where b.code is null
  ),
  deny_missing as (
    select b.code
    from base_codes b
    left join desired_codes d on d.code = b.code
    where d.code is null
  )
  insert into public.user_permission_overrides (
    user_id,
    permission_id,
    business_id,
    allow,
    created_by
  )
  select v_user_id, p.id, p_business_id, true, auth.uid()
  from allow_extra a
  join public.permissions p on p.code = a.code
  union all
  select v_user_id, p.id, p_business_id, false, auth.uid()
  from deny_missing d
  join public.permissions p on p.code = d.code;
end;
$$;

-- 3) Alinear catálogo Dart con BD: dar a manager los permisos de gestión
--    de usuarios que el catálogo declara (settings.usuarios.crear,
--    .editar, .desactivar). Idempotente.
do $$
declare
  v_business_id uuid;
  v_role_id uuid;
  v_perm_codes text[] := array[
    'settings.usuarios.crear',
    'settings.usuarios.editar',
    'settings.usuarios.desactivar'
  ];
  v_code text;
begin
  for v_business_id in
    select id from public.businesses
  loop
    select id into v_role_id
      from public.roles
      where business_id = v_business_id
        and lower(name) = 'manager'
        and is_system = true
      limit 1;

    if v_role_id is null then
      continue;
    end if;

    foreach v_code in array v_perm_codes loop
      insert into public.role_permissions (role_id, permission_id, allow)
      select v_role_id, p.id, true
        from public.permissions p
        where p.code = v_code
      on conflict (role_id, permission_id) do update
        set allow = true;
    end loop;
  end loop;
end;
$$;

commit;

-- =============================================================================
-- Smoke checks (ejecutar después de aplicar)
-- =============================================================================
-- 1. Verificar la jerarquía:
--    select public.fn_role_hierarchy('owner'),
--           public.fn_role_hierarchy('admin'),
--           public.fn_role_hierarchy('manager'),
--           public.fn_role_hierarchy('waiter');
--
-- 2. Como Admin, intentar asignar rol Admin u Owner debe fallar:
--    -- (esperado: CANNOT_ASSIGN_ROLE_AT_OR_ABOVE_OWN_HIERARCHY)
--
-- 3. Como Manager, intentar asignar Manager debe fallar; asignar Waiter debe pasar.
--
-- 4. Como Owner, asignar cualquier rol (incluso owner) debe pasar.
--
-- 5. Verificar permisos de Manager incluyen crear/editar/desactivar:
--    select rp.allow, p.code
--      from role_permissions rp
--      join roles r on r.id = rp.role_id
--      join permissions p on p.id = rp.permission_id
--      where lower(r.name) = 'manager'
--        and p.code like 'settings.usuarios.%'
--      order by p.code;
