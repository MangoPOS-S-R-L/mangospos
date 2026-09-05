-- =====================================================================
-- Acceso de PROPIETARIO para 2 usuarios en 3 negocios
--   argeli@sophisticatedservice.do
--   karen@sophisticatedservice.do
-- Negocios:
--   af2ec2e7-2cdd-4583-bf5a-7e7476173b72
--   f054fbc2-3fb7-4e34-a020-11341ff11d84
--   9c1886d5-736c-49ae-b8ae-55ffae6017a8
--
-- Mecanismo: fila en public.user_businesses con role='owner'.
--   - RLS: current_user_business_ids() = memberships ∪ user_businesses
--   - App: session_controller arma el switcher desde user_businesses y,
--     con role owner/admin, los permisos efectivos son wildcard '*'.
-- NO se toca businesses.owner_id (eso es el dueño real / billing).
-- NO se tocan memberships (el cobro va por is_billing_anchor, por negocio).
-- =====================================================================


-- ============== PASO 1: PREFLIGHT (leer antes de escribir) ==============

-- 1a. ¿Existen los 2 usuarios en auth? (si falta alguno, hay que crearle
--     el login primero; sin fila en auth.users no se le puede dar acceso)
select
  e.email                                   as email_pedido,
  u.id                                      as user_id,
  u.email_confirmed_at,
  u.last_sign_in_at,
  case when u.id is null then 'FALTA: no existe login' else 'OK' end as estado
from (values
  ('argeli@sophisticatedservice.do'),
  ('karen@sophisticatedservice.do')
) as e(email)
left join auth.users u on lower(u.email) = e.email
order by e.email;

-- 1b. ¿Existen los 3 negocios?
select b.id, b.business_name, b.branch_name, b.status, b.domain, b.owner_id
from public.businesses b
where b.id in (
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
  'f054fbc2-3fb7-4e34-a020-11341ff11d84',
  '9c1886d5-736c-49ae-b8ae-55ffae6017a8'
)
order by b.business_name, b.branch_name;

-- 1c. ¿Qué acceso tienen HOY? (para saber qué se está pisando)
select u.email, b.business_name, b.branch_name, ub.role, ub.permissions, ub.created_at
from public.user_businesses ub
join auth.users u on u.id = ub.user_id
join public.businesses b on b.id = ub.business_id
where lower(u.email) in (
  'argeli@sophisticatedservice.do',
  'karen@sophisticatedservice.do'
)
order by u.email, b.business_name;


-- ============== PASO 2: DAR EL ACCESO (2 usuarios × 3 negocios = 6 filas) ==============

begin;

insert into public.user_businesses (user_id, business_id, role, permissions)
select u.id, b.id, 'owner', array['all']::text[]
from auth.users u
cross join public.businesses b
where lower(u.email) in (
        'argeli@sophisticatedservice.do',
        'karen@sophisticatedservice.do'
      )
  and b.id in (
        'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
        'f054fbc2-3fb7-4e34-a020-11341ff11d84',
        '9c1886d5-736c-49ae-b8ae-55ffae6017a8'
      )
on conflict (user_id, business_id) do update
  set role        = 'owner',
      permissions = array['all']::text[]
returning user_id, business_id, role;

-- Deben salir 6 filas. Si salen menos, falta un login (PASO 1a) o un
-- negocio no existe (PASO 1b): haz ROLLBACK y arregla eso primero.

commit;


-- ============== PASO 3: VERIFICAR ==============

select u.email, b.business_name, b.branch_name, b.id as business_id,
       ub.role, ub.permissions
from public.user_businesses ub
join auth.users u on u.id = ub.user_id
join public.businesses b on b.id = ub.business_id
where lower(u.email) in (
        'argeli@sophisticatedservice.do',
        'karen@sophisticatedservice.do'
      )
  and ub.business_id in (
        'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
        'f054fbc2-3fb7-4e34-a020-11341ff11d84',
        '9c1886d5-736c-49ae-b8ae-55ffae6017a8'
      )
order by u.email, b.business_name, b.branch_name;
-- Esperado: 6 filas, todas role='owner', permissions={all}.


-- ============== OPCIONAL: identidad en el POS (empleado + PIN) ==============
-- Lo de arriba da ACCESO y permisos totales. NO crea la ficha de empleado
-- (PIN, atribución de mesero/cajero). Si además las quieres como empleadas
-- en cada negocio, dime y te paso el INSERT en public.employees
-- (business_id, user_id, first_name, last_name, email, phone) por negocio.
