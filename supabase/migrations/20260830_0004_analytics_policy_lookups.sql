-- 20260830_0004_analytics_policy_lookups.sql
-- Ultima capa del mismo problema. Tras 20260830_0003 quedaban 3 vistas rotas (verificado por
-- HTTP contra prod con la API key real):
--     print_area_printers  -> permission denied for table employees
--     print_areas          -> permission denied for table businesses
--     secuencias_ncf       -> permission denied for table employees
--
-- Misma causa: sus policies consultan esas tablas inline en vez de usar un helper
-- SECURITY DEFINER, y ese acceso se valida contra el invocador (analytics_ro).
--
-- Los errores salen de a uno: cada barrido destapa la siguiente tabla que hace falta. Por eso
-- fueron tres rondas (auth -> user_businesses/memberships -> employees/businesses) y no una.
--
-- SOBRE LA EXPOSICION: se temia que el grant permitiera leer estas tablas por
-- `Accept-Profile: public`, fuera del esquema analytics. MEDIDO CONTRA PROD: no ocurre.
-- Devuelven [] vacio. Las policies son `TO authenticated` y, evaluadas directamente como
-- analytics_ro (que es NOINHERIT y no es miembro de authenticated), no aplican: sin policy
-- que de acceso, cero filas. Dentro de las vistas definer si aplican, porque alli la RLS se
-- evalua como el owner de la vista, que si es miembro de authenticated.
-- O sea: el grant solo habilita la EVALUACION de las policies, no una via de lectura.
-- Idempotente.

begin;

grant select on public.employees  to analytics_ro;
grant select on public.businesses to analytics_ro;

commit;


-- Verificacion
do $$
declare
  v_otros int;
begin
  raise notice 'SELECT employees: %  | SELECT businesses: %',
    has_table_privilege('analytics_ro', 'public.employees', 'SELECT'),
    has_table_privilege('analytics_ro', 'public.businesses', 'SELECT');

  -- La RLS debe seguir siendo la barrera: simular la API key y contar negocios visibles.
  perform set_config('request.jwt.claim.sub',
                     (select u.id::text from auth.users u
                       where u.email = 'lectura.penda@mangopos.do'), true);

  select count(*) into v_otros from analytics.businesses
   where id <> '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';

  raise notice 'Negocios visibles que NO son Penda: %  (debe ser 0)', v_otros;
  if v_otros > 0 then
    raise warning 'PELIGRO: se ven otros negocios. Revertir.';
  end if;
end $$;

notify pgrst, 'reload schema';
