-- =====================================================================
-- 20260508_0012_fix_save_access_profile_overrides.sql
--
-- Fix: `fn_save_user_access_profile` insertaba en
-- `user_permission_overrides` sin proveer `employee_id`, una columna
-- que en producción es NOT NULL. Esto rompía la creación de cualquier
-- usuario con un mensaje del tipo:
--   null value in column "employee_id" of relation
--   "user_permission_overrides" violates not-null constraint
--
-- También ajustamos el DELETE previo para usar `employee_id` como
-- llave (en producción la fila se identifica por employee_id, no por
-- user_id+business_id).
--
-- El resto del cuerpo de la función (employee_roles, user_businesses,
-- user_roles) queda igual.
-- =====================================================================

begin;

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
begin
  if public.user_business_role(auth.uid(), p_business_id) not in ('owner', 'admin') then
    raise exception 'ACCESS_DENIED';
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

  -- Si el empleado no tiene auth user, los permission overrides
  -- per-user no aplican (no hay a quién aplicárselos vía RLS).
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

  -- En producción `user_permission_overrides` se identifica por
  -- (employee_id, permission_id) y employee_id es NOT NULL. Borramos
  -- e insertamos por employee_id, y poblamos las columnas adicionales
  -- (user_id, business_id) para mantener compatibilidad con código
  -- legacy que las consulta.
  delete from public.user_permission_overrides
  where employee_id = p_employee_id;

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
    employee_id,
    user_id,
    permission_id,
    business_id,
    allow,
    created_by
  )
  select p_employee_id, v_user_id, p.id, p_business_id, true, auth.uid()
  from allow_extra a
  join public.permissions p on p.code = a.code
  union all
  select p_employee_id, v_user_id, p.id, p_business_id, false, auth.uid()
  from deny_missing d
  join public.permissions p on p.code = d.code;
end;
$$;

grant execute on function public.fn_save_user_access_profile(uuid, uuid, uuid[], text, text[]) to authenticated;

commit;
