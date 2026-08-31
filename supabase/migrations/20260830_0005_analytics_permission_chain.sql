-- 20260830_0005_analytics_permission_chain.sql
-- Cierra la cadena de permisos de golpe, en vez de descubrirla tabla por tabla.
--
-- Tras 20260830_0004 quedaban print_area_printers y secuencias_ncf pidiendo employee_roles.
-- Sus policies recorren a mano la cadena granular de permisos del POS:
--     employees -> employee_roles -> role_permissions -> permissions
-- (la misma que hace public.user_has_business_permission(), pero esa SI es SECURITY DEFINER
--  y por eso las policies que la llaman nunca dieron problema).
--
-- Postgres reporta una tabla por vez, asi que ir de a una habria costado 3 rondas mas. Aqui
-- se otorga la cadena entera mas los dos anexos de roles que aparecen en variantes de esas
-- policies (roles, user_roles, user_permission_overrides).
--
-- EXPOSICION: las 6 tablas YA se publican como vistas en analytics (estan en el allowlist
-- desde 20260829_0002), asi que el grant no agrega ni un dato nuevo al alcance del cliente.
-- Solo permite que la evaluacion de las policies las lea. La RLS de cada una sigue vigente.
-- Idempotente.

begin;

grant select on public.employee_roles            to analytics_ro;
grant select on public.role_permissions          to analytics_ro;
grant select on public.permissions               to analytics_ro;
grant select on public.roles                     to analytics_ro;
grant select on public.user_roles                to analytics_ro;
grant select on public.user_permission_overrides to analytics_ro;

commit;


-- Verificacion: inventario completo de lo que analytics_ro puede leer en public, y si cada
-- una esta o no publicada como vista.
--
-- OJO: hay que pasar el OID a has_table_privilege, no el nombre. Con el nombre
-- ('public.'||tablename) el planificador puede evaluar la funcion ANTES del filtro
-- schemaname='public' -- no hay orden garantizado en el WHERE -- y revienta con
-- 42P01 relation "public.flow_state" does not exist al toparse con tablas de otros esquemas.
select
  c.relname as tabla_public,
  case when v.table_name is null
       then 'NO publicada (solo para evaluar policies)'
       else 'publicada como analytics.' || v.table_name end as estado
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join information_schema.tables v
       on v.table_schema = 'analytics' and v.table_name = c.relname
where n.nspname = 'public'
  and c.relkind = 'r'
  and has_table_privilege('analytics_ro', c.oid, 'SELECT')
order by 2, 1;
