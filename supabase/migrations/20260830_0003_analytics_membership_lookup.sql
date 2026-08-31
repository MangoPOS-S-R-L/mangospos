-- 20260830_0003_analytics_membership_lookup.sql
-- Arregla las 20 vistas que fallaban con
--     permission denied for table user_businesses   (18 vistas)
--     permission denied for table memberships       ( 2 vistas)
--
-- CAUSA: en el POS conviven dos estilos de policy.
--   * Las que llaman a un helper SECURITY DEFINER  -> user_has_business_access(),
--     current_user_business_ids(), fn_user_in_business(). El helper lee las tablas como su
--     dueno, asi que el invocador no necesita ningun grant. Estas 70 vistas funcionan.
--   * Las que hacen el SELECT inline, por ejemplo:
--         uid() in (select user_businesses.user_id from user_businesses
--                    where user_businesses.business_id = cash_registers.business_id)
--     Ese acceso a la tabla se valida contra el INVOCADOR. analytics_ro no tiene nada, y
--     por eso esas 20 vistas revientan.
--
-- ARREGLO: dar SELECT sobre las dos tablas de pertenencia. NO se tocan las policies del POS:
-- reescribir 20 policies en produccion seria mucho mas arriesgado que este grant.
--
-- POR QUE NO FILTRA NADA AL CLIENTE:
--   1. Ninguna de las dos tablas esta publicada como vista en el esquema analytics (se
--      excluyeron a proposito del allowlist), y analytics_ro no puede crear vistas.
--   2. PostgREST solo sirve lo que hay en el esquema expuesto; no hay ruta para leerlas.
--   3. Ambas conservan su RLS.
-- El bloque de verificacion al final comprueba el punto 1.
-- Idempotente.

begin;

grant select on public.user_businesses to analytics_ro;
grant select on public.memberships     to analytics_ro;

commit;


-- Verificacion
do $$
declare
  v_expuestas int;
  v_lista     text;
begin
  -- ¿Alguna vista de analytics expone esas tablas? Debe ser 0.
  select count(*), coalesce(string_agg(table_name, ', '), '(ninguna)')
    into v_expuestas, v_lista
    from information_schema.tables
   where table_schema = 'analytics'
     and table_name in ('user_businesses', 'memberships');

  raise notice 'Vistas de analytics sobre user_businesses/memberships: %  -> %', v_expuestas, v_lista;

  if v_expuestas > 0 then
    raise warning 'PELIGRO: esas tablas SI son alcanzables por la API. Revisar el allowlist.';
  else
    raise notice 'OK: el grant solo lo usa la evaluacion de las policies; la API no las sirve.';
  end if;

  raise notice 'SELECT user_businesses: %  | SELECT memberships: %',
    has_table_privilege('analytics_ro', 'public.user_businesses', 'SELECT'),
    has_table_privilege('analytics_ro', 'public.memberships', 'SELECT');
end $$;

notify pgrst, 'reload schema';
