-- ronancyf@elencuentro.com (082b0987): acceso directo en EL ENCUENTRO y DON REY,
-- sin quitarle FOOD SHOP. Copia el rol y los permisos[] de su fila de FOOD SHOP
-- y sus roles (por NOMBRE). Idempotente.
--   * EL ENCUENTRO ya la veía por shared_across_branches (mismo owner_id), pero
--     cajas/cierres exigen fila DIRECTA en user_businesses (fn_user_in_business).
--   * DON REY tiene otro owner_id: el compartido no llega ahí.
-- Las filas nuevas van con shared_across_branches = false: en DON REY la marca
-- abriría todas las sucursales de ESE dueño.
do $$
declare
  c_foodshop  constant uuid := 'f054fbc2-3fb7-4e34-a020-11341ff11d84';
  c_encuentro constant uuid := 'af2ec2e7-2cdd-4583-bf5a-7e7476173b72';
  c_donrey    constant uuid := '9c1886d5-736c-49ae-b8ae-55ffae6017a8';
  c_uid       constant uuid := '082b0987-eac2-4115-9e19-0693c88d2928';
  v_src public.user_businesses%rowtype;
begin
  if not exists (select 1 from auth.users where id = c_uid) then
    raise exception 'NO EXISTE el login %: no se hizo nada', c_uid;
  end if;

  select * into v_src
  from public.user_businesses
  where user_id = c_uid and business_id = c_foodshop;
  if not found then
    raise exception 'No tiene fila en FOOD SHOP para copiar: no se hizo nada';
  end if;

  if (select count(*) from public.businesses where id in (c_encuentro, c_donrey)) <> 2 then
    raise exception 'Falta EL ENCUENTRO o DON REY en businesses: no se hizo nada';
  end if;

  -- 1. Acceso directo, mismo rol y permisos[] que en FOOD SHOP
  insert into public.user_businesses (user_id, business_id, role, permissions)
  select c_uid, t.id, v_src.role, v_src.permissions
  from (values (c_encuentro), (c_donrey)) t(id)
  on conflict (user_id, business_id) do nothing;

  -- 2. Roles de FOOD SHOP, buscados por NOMBRE en cada negocio (son por negocio)
  insert into public.user_roles (user_id, role_id, business_id)
  select c_uid, rd.id, t.id
  from public.user_roles ur
  join public.roles rs on rs.id = ur.role_id
  cross join (values (c_encuentro), (c_donrey)) t(id)
  join public.roles rd on rd.business_id = t.id
                      and lower(trim(rd.name)) = lower(trim(rs.name))
  where ur.user_id = c_uid and ur.business_id = c_foodshop
  on conflict do nothing;
end $$;

-- Reporte: cómo quedó en cada negocio (una sola tabla para el SQL Editor)
with neg(business_id) as (values
  ('af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid),
  ('f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid),
  ('9c1886d5-736c-49ae-b8ae-55ffae6017a8'::uuid))
select
  coalesce(b.branch_name, b.business_name)                            as negocio,
  coalesce(ub.role, 'SIN FILA')                                       as rol_acceso,
  case when ub.id is not null then 'SI' else 'NO' end                 as ve_cajas,
  coalesce(ub.shared_across_branches, false)                          as compartida,
  coalesce((select string_agg(r.name, ', ' order by r.name)
              from public.user_roles ur join public.roles r on r.id = ur.role_id
             where ur.user_id = '082b0987-eac2-4115-9e19-0693c88d2928'
               and ur.business_id = n.business_id), '(ninguno)')     as roles,
  (select count(*) from public.fn_user_effective_permissions(
      '082b0987-eac2-4115-9e19-0693c88d2928', n.business_id) p
    where p.allowed)                                                  as permisos_efectivos
from neg n
join public.businesses b on b.id = n.business_id
left join public.user_businesses ub
  on ub.user_id = '082b0987-eac2-4115-9e19-0693c88d2928' and ub.business_id = n.business_id
order by negocio;
