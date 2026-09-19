-- =============================================================================
-- DIAGNÓSTICO · Transferir caja abierta entre usuarios
-- Negocio: 6d13ed3f-0fb9-40e3-a695-f4c09759fbfd
--
-- Solo lectura. Devuelve UNA sola tabla (el SQL Editor de Supabase solo
-- muestra el último resultado):
--   1 CAJA ABIERTA  → cada sesión abierta del negocio, su dueño actual y lo
--                     que ya tiene registrado (cobros y movimientos).
--   2 CANDIDATO     → usuarios con cuenta que pueden recibir la caja.
--                     "BLOQUEADO" = ya tiene otra caja abierta (la BD permite
--                     una sola caja abierta por usuario).
--   3 SIN CUENTA    → empleados solo-PIN: NO se les puede asignar caja,
--                     la caja se amarra a una cuenta de auth.users.
-- =============================================================================
with biz as (
  select id, owner_id, business_name
  from public.businesses
  where id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
),
open_sessions as (
  select s.id            as session_id,
         s.user_id,
         s.opened_at,
         s.start_amount,
         s.device_name,
         r.name          as register_name
  from public.cash_register_sessions s
  join public.cash_registers r on r.id = s.cash_register_id
  join biz b on b.id = r.business_id
  where s.status = 'open'
    and s.closed_at is null
),
access as (
  -- Todo el que tiene acceso al negocio con cuenta de auth
  select ub.user_id, ub.role
  from public.user_businesses ub
  join biz b on b.id = ub.business_id
  union
  select b.owner_id, 'owner' from biz b
),
people as (
  select a.user_id,
         string_agg(distinct a.role, ', ')              as roles,
         max(u.email)                                     as email,
         coalesce(max(p.full_name),
                  max(nullif(trim(e.first_name || ' ' || e.last_name), ''))) as full_name
  from access a
  join auth.users u on u.id = a.user_id
  left join public.profiles p on p.id = a.user_id
  left join public.employees e
         on e.user_id = a.user_id
        and e.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
  group by a.user_id
),
any_open as (
  -- Caja abierta del usuario en CUALQUIER negocio (el índice único es global)
  select s.user_id,
         string_agg(coalesce(bb.business_name, '?') || ' / ' || coalesce(r.name, '?')
                    || ' desde ' || to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
                    '; ') as detalle
  from public.cash_register_sessions s
  left join public.cash_registers r on r.id = s.cash_register_id
  left join public.businesses bb on bb.id = r.business_id
  where s.status = 'open' and s.closed_at is null
  group by s.user_id
)
select seccion, id, nombre, email, rol, detalle
from (
  -- 1) Cajas abiertas del negocio
  select 1 as orden,
         '1 CAJA ABIERTA' as seccion,
         os.session_id::text as id,
         coalesce(pe.full_name, '(sin nombre)') as nombre,
         coalesce(pe.email, (select email from auth.users where id = os.user_id)) as email,
         coalesce(pe.roles, '(sin acceso al negocio)') as rol,
         format('Caja "%s" · abierta %s · fondo %s · equipo %s · cobros: %s por %s · movimientos de caja: %s',
                os.register_name,
                to_char(os.opened_at at time zone 'America/Santo_Domingo', 'DD/MM/YYYY HH24:MI'),
                os.start_amount,
                coalesce(os.device_name, '?'),
                (select count(*) from public.payments py
                  where py.session_id = os.session_id and py.status = 'completed'),
                (select coalesce(sum(py.amount), 0) from public.payments py
                  where py.session_id = os.session_id and py.status = 'completed'),
                (select count(*) from public.cash_transactions ct
                  where ct.session_id = os.session_id)) as detalle
  from open_sessions os
  left join people pe on pe.user_id = os.user_id

  union all

  -- 2) Usuarios con cuenta que pueden recibirla
  select 2,
         '2 CANDIDATO',
         pe.user_id::text,
         coalesce(pe.full_name, '(sin nombre)'),
         pe.email,
         pe.roles,
         case
           when exists (select 1 from open_sessions os where os.user_id = pe.user_id)
             then 'Dueño ACTUAL de una caja abierta de este negocio (sección 1)'
           when ao.user_id is not null then 'BLOQUEADO: ya tiene caja abierta → ' || ao.detalle
           else 'OK para recibir la caja'
         end
  from people pe
  left join any_open ao on ao.user_id = pe.user_id

  union all

  -- 3) Empleados solo-PIN (sin cuenta)
  select 3,
         '3 SIN CUENTA',
         e.id::text,
         trim(e.first_name || ' ' || e.last_name),
         e.email,
         coalesce(e.position, e.department, '-'),
         'NO asignable: empleado solo con PIN, sin usuario de acceso'
  from public.employees e
  where e.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and e.user_id is null
    and e.status = 'active'
) t
order by orden, nombre;
