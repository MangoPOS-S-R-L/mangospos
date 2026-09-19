-- ¿Quién es 9606d43d-df47-4759-8100-7bb25caf9ae0? No salió en los candidatos
-- del diagnóstico de transferencia de caja (negocio 6d13ed3f). Solo lectura,
-- una sola tabla.
with x as (select '9606d43d-df47-4759-8100-7bb25caf9ae0'::uuid as id),
hits as (
  select 1 as orden, 'CUENTA (auth.users)' as donde, u.email,
         coalesce(p.full_name, '') as nombre,
         coalesce((select string_agg(b.business_name || ' → ' || ub.role, '; ')
                     from public.user_businesses ub
                     join public.businesses b on b.id = ub.business_id
                    where ub.user_id = u.id),
                  'sin fila en user_businesses') as detalle
  from auth.users u
  join x on u.id = x.id
  left join public.profiles p on p.id = u.id

  union all
  select 2, 'FICHA DE EMPLEADO (employees)', e.email,
         trim(e.first_name || ' ' || e.last_name),
         format('negocio %s · status %s · cuenta de acceso: %s · acceso a 6d13ed3f: %s',
                coalesce(b.business_name, '?'), e.status,
                coalesce(u.email || ' (' || u.id || ')', 'NINGUNA, solo PIN'),
                case when e.user_id is null then 'n/a'
                     when exists (select 1 from public.user_businesses ub
                                   where ub.user_id = e.user_id
                                     and ub.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd')
                       or exists (select 1 from public.businesses bb
                                   where bb.id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
                                     and bb.owner_id = e.user_id)
                     then 'SÍ' else 'NO' end)
  from public.employees e
  join x on e.id = x.id or e.user_id = x.id
  left join public.businesses b on b.id = e.business_id
  left join auth.users u on u.id = e.user_id

  union all
  select 3, 'FILA DE ACCESO (user_businesses)', u.email, '',
         format('negocio %s · rol %s', coalesce(b.business_name, '?'), ub.role)
  from public.user_businesses ub
  join x on ub.id = x.id
  left join public.businesses b on b.id = ub.business_id
  left join auth.users u on u.id = ub.user_id

  union all
  select 4, 'NEGOCIO (businesses)', null, b.business_name, 'el id es de un negocio, no de un usuario'
  from public.businesses b
  join x on b.id = x.id

  union all
  select 5, 'SESIÓN DE CAJA (cash_register_sessions)', u.email, coalesce(r.name, '?'), s.status
  from public.cash_register_sessions s
  join x on s.id = x.id
  left join public.cash_registers r on r.id = s.cash_register_id
  left join auth.users u on u.id = s.user_id
)
select donde, email, nombre, detalle from hits
union all
select 'NO ENCONTRADO', null, null, 'Ese id no está en cuentas, empleados, accesos, negocios ni sesiones de caja'
where not exists (select 1 from hits)
order by 1;
