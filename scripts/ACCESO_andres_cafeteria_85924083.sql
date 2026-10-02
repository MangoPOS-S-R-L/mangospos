-- v3 (2026-10-02): permisos personalizados por employee_id. Si el error menciona
-- 'insert into public.user_permission_overrides (user_id, ...' estás corriendo una versión vieja.
-- Andrés Ferreiras (andres@sportclub.com): cajero también en la CAFETERIA (85924083),
-- sin quitarle la TIENDA (40b0fa9d). Copia su ficha de empleado (con PIN si no choca),
-- sus roles (por nombre) y sus permisos personalizados. Idempotente.
do $$
declare
  c_cafe   constant uuid := '85924083-2e8e-4e64-8192-808ee24674ed';
  c_tienda constant uuid := '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab';
  c_email  constant text := 'andres@sportclub.com';
  v_uid uuid;
  v_src public.employees%rowtype;
  v_emp uuid;
  v_pin text;
  v_cols text;
begin
  select id into v_uid from auth.users where lower(email) = c_email;
  if v_uid is null then
    raise exception 'NO EXISTE la cuenta %: no se hizo nada', c_email;
  end if;

  select * into v_src
  from public.employees
  where business_id = c_tienda and (user_id = v_uid or lower(email) = c_email)
  order by (status = 'active') desc, created_at desc
  limit 1;
  if not found then
    raise exception 'Andres no tiene ficha de empleado en la TIENDA: no se hizo nada';
  end if;

  -- 1. Acceso a la cafetería (como lo crea la app: cajero sin permisos[] propios)
  insert into public.user_businesses (user_id, business_id, role, permissions)
  values (v_uid, c_cafe, 'cashier', array[]::text[])
  on conflict (user_id, business_id) do nothing;

  -- 2. Ficha de empleado en la cafetería (solo si no tiene una)
  select id into v_emp
  from public.employees
  where business_id = c_cafe and (user_id = v_uid or lower(email) = c_email)
  limit 1;

  if v_emp is null then
    v_pin := nullif(trim(v_src.pin), '');
    if v_pin is not null and exists (
         select 1 from public.employees
         where business_id = c_cafe and status = 'active' and trim(pin) = v_pin) then
      v_pin := null;  -- otro empleado activo de la cafetería ya usa ese PIN
    end if;

    -- Copia TODAS las columnas que existan en la BD viva (difiere del repo),
    -- salvo las que se fijan aquí. pin_hash lo recalcula el trigger desde pin.
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
    from information_schema.columns
    where table_schema = 'public' and table_name = 'employees'
      and column_name not in ('id', 'business_id', 'user_id', 'pin', 'pin_hash',
                              'created_at', 'updated_at')
      and is_generated = 'NEVER'
      and coalesce(is_identity, 'NO') = 'NO';

    execute format(
      'insert into public.employees (business_id, user_id, pin, %1$s)
       select $1, $2, $3, %1$s from public.employees where id = $4
       returning id', v_cols)
    into v_emp
    using c_cafe, v_uid, v_pin, v_src.id;
  end if;

  -- 3. Roles: los mismos de la tienda, buscados por NOMBRE en la cafetería
  insert into public.employee_roles (employee_id, role_id)
  select v_emp, rc.id
  from public.employee_roles er
  join public.roles rt on rt.id = er.role_id
  join public.roles rc on rc.business_id = c_cafe and lower(trim(rc.name)) = lower(trim(rt.name))
  where er.employee_id = v_src.id
  on conflict do nothing;

  insert into public.user_roles (user_id, role_id, business_id)
  select v_uid, rc.id, c_cafe
  from public.user_roles ur
  join public.roles rt on rt.id = ur.role_id
  join public.roles rc on rc.business_id = c_cafe and lower(trim(rc.name)) = lower(trim(rt.name))
  where ur.user_id = v_uid and ur.business_id = c_tienda
  on conflict do nothing;

  -- 4. Permisos personalizados: en la BD viva se guardan POR FICHA (employee_id
  --    NOT NULL), igual que fn_save_user_access_profile. De la ficha de la
  --    tienda a la ficha nueva de la cafetería.
  insert into public.user_permission_overrides (employee_id, user_id, permission_id, business_id, allow)
  select v_emp, v_uid, o.permission_id, c_cafe, o.allow
  from public.user_permission_overrides o
  where o.employee_id = v_src.id
  on conflict do nothing;
end $$;

-- Reporte: cómo quedó Andrés en cada sucursal
with u as (select id from auth.users where lower(email) = 'andres@sportclub.com'),
neg(business_id) as (values ('85924083-2e8e-4e64-8192-808ee24674ed'::uuid),
                            ('40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab'::uuid))
select
  coalesce(b.branch_name, b.business_name)                         as sucursal,
  ub.role                                                          as rol_acceso,
  e.first_name || ' ' || e.last_name || ' (' || e.status || ')'    as ficha_empleado,
  case when nullif(trim(e.pin), '') is not null then 'SI'
       when e.id is null then '-'
       else 'NO: choca con otro empleado o no tenia; asignalo en la app' end as pin,
  coalesce((select string_agg(r.name, ', ' order by r.name)
              from public.employee_roles er join public.roles r on r.id = er.role_id
             where er.employee_id = e.id), '(ninguno)')            as roles,
  (select count(*) from public.fn_user_effective_permissions(u.id, n.business_id) p
    where p.allowed)                                               as permisos_efectivos,
  (select count(*) from public.user_permission_overrides o
    where o.employee_id = e.id)                                    as personalizados
from u
cross join neg n
join public.businesses b            on b.id = n.business_id
left join public.user_businesses ub on ub.user_id = u.id and ub.business_id = n.business_id
left join public.employees e        on e.business_id = n.business_id and e.user_id = u.id
order by sucursal;
