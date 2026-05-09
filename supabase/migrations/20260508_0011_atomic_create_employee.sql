-- =====================================================================
-- 20260508_0011_atomic_create_employee.sql
--
-- Crear empleado/usuario en una sola transacción.
--
-- Problema: la creación de un usuario nuevo desde la app requería
-- 3+ llamadas separadas (create_new_user → INSERT employees →
-- fn_save_user_access_profile). Si la última fallaba, quedaba un
-- usuario en auth.users + employees pero SIN fila en user_businesses,
-- por lo que no aparecía asignado a ningún negocio.
--
-- Fix: un único RPC `fn_create_employee_with_access` que hace todo
-- atómicamente. Si cualquier paso falla, postgres revierte todo
-- (savepoint implícito) y el cliente no queda con estado parcial.
--
-- Cubre:
--   1. Validación de permisos (caller debe ser owner/admin del negocio)
--   2. Crear auth.users + identities + profiles (vía create_new_user)
--   3. Insertar user_businesses con el rol primario
--   4. Insertar fila en employees
--   5. Asignar employee_roles + user_roles iniciales
--
-- Después de este RPC, el cliente puede llamar a
-- fn_save_user_access_profile para ajustar permission overrides; ese
-- paso ya no es crítico para la asignación al negocio.
-- =====================================================================

begin;

create or replace function public.fn_create_employee_with_access(
  p_business_id uuid,
  p_email text,
  p_password text,
  p_employee_data jsonb,
  p_primary_role text default null,
  p_role_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_employee_id uuid;
  v_normalized_role text;
  v_employee_row jsonb;
begin
  -- Permiso: solo owner/admin pueden crear usuarios en este negocio.
  if public.user_business_role(auth.uid(), p_business_id) not in ('owner','admin') then
    raise exception 'ACCESS_DENIED';
  end if;

  if p_employee_data is null then
    raise exception 'EMPLOYEE_DATA_REQUIRED';
  end if;

  v_normalized_role := case
    when lower(coalesce(p_primary_role,'')) in ('owner','admin','manager','cashier','waiter','delivery')
      then lower(p_primary_role)
    when lower(coalesce(p_primary_role,'')) in ('cook','chef') then 'cook'
    else 'waiter'
  end;

  -- 1. Auth user (solo si hay password). Reusamos create_new_user que
  --    maneja auth.users + auth.identities + profiles.
  if p_password is not null and length(trim(p_password)) > 0 then
    v_user_id := public.create_new_user(
      p_email,
      p_password,
      jsonb_build_object(
        'first_name', p_employee_data->>'first_name',
        'last_name',  p_employee_data->>'last_name',
        'business_id', p_business_id::text
      )
    );

    -- 2. user_businesses — esto es lo que el flujo viejo a veces no
    --    alcanzaba a insertar. Atómico con la creación del auth user.
    insert into public.user_businesses (user_id, business_id, role, permissions, created_at)
    values (
      v_user_id,
      p_business_id,
      v_normalized_role,
      case when v_normalized_role in ('owner','admin')
        then array['all']::text[]
        else array[]::text[]
      end,
      now()
    )
    on conflict (user_id, business_id) do update
      set role = excluded.role,
          permissions = excluded.permissions;
  end if;

  -- 3. Empleado.
  insert into public.employees (
    business_id, user_id, first_name, last_name, email, phone,
    national_id, gender, address, status, hire_date, contract_type,
    department, position, work_schedule, salary_base, pay_frequency,
    bank_name, bank_account, emergency_name, emergency_relation,
    emergency_phone, pin
  )
  values (
    p_business_id,
    v_user_id,
    p_employee_data->>'first_name',
    p_employee_data->>'last_name',
    p_employee_data->>'email',
    p_employee_data->>'phone',
    nullif(p_employee_data->>'national_id', ''),
    nullif(p_employee_data->>'gender', ''),
    nullif(p_employee_data->>'address', ''),
    coalesce(nullif(p_employee_data->>'status',''), 'active'),
    nullif(p_employee_data->>'hire_date','')::date,
    nullif(p_employee_data->>'contract_type',''),
    nullif(p_employee_data->>'department',''),
    nullif(p_employee_data->>'position',''),
    nullif(p_employee_data->>'work_schedule',''),
    nullif(p_employee_data->>'salary_base','')::numeric,
    nullif(p_employee_data->>'pay_frequency',''),
    nullif(p_employee_data->>'bank_name',''),
    nullif(p_employee_data->>'bank_account',''),
    nullif(p_employee_data->>'emergency_name',''),
    nullif(p_employee_data->>'emergency_relation',''),
    nullif(p_employee_data->>'emergency_phone',''),
    nullif(p_employee_data->>'pin','')
  )
  returning id into v_employee_id;

  -- 4. Roles iniciales.
  if p_role_ids is not null and coalesce(array_length(p_role_ids, 1), 0) > 0 then
    insert into public.employee_roles (employee_id, role_id)
    select v_employee_id, role_id from unnest(p_role_ids) as role_id
    on conflict do nothing;

    if v_user_id is not null then
      insert into public.user_roles (user_id, role_id, business_id, created_by)
      select v_user_id, role_id, p_business_id, auth.uid()
      from unnest(p_role_ids) as role_id
      on conflict do nothing;
    end if;
  end if;

  -- Devolver la fila completa de employees para que el cliente la
  -- mapee directamente sin un round-trip extra.
  select to_jsonb(e.*) into v_employee_row
  from public.employees e
  where e.id = v_employee_id;

  return jsonb_build_object(
    'employee', v_employee_row,
    'user_id', v_user_id
  );
end;
$$;

grant execute on function public.fn_create_employee_with_access(uuid, text, text, jsonb, text, uuid[]) to authenticated;

commit;
