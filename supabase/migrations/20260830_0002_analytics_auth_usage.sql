-- 20260830_0002_analytics_auth_usage.sql
-- Arregla las vistas que fallaban con "permission denied for schema auth".
--
-- SINTOMA: GET /cash_register_sessions con la API key devolvia
--     {"code":"42501","message":"permission denied for schema auth"}
-- mientras que como `postgres` la misma vista funcionaba.
--
-- CAUSA (medida en prod):
--     USAGE sobre auth:  analytics_ro=false  view_owner=true  authenticated=true  anon=true
-- analytics_ro es NOINHERIT a proposito, para que no herede los grants de escritura de
-- `authenticated`. El efecto colateral es que tampoco hereda el USAGE sobre el esquema auth.
-- Las policies de cash_register_sessions / cash_registers son `TO public` (aplican a TODOS los
-- roles) y llaman a auth.uid() en su expresion; resolver esa funcion se valida contra el
-- INVOCADOR, no contra el owner de la vista. Es la misma regla que obligo a dar EXECUTE de
-- analytics.allowed_business_id() a analytics_ro en 20260829_0002.
--
-- ARREGLO: dar USAGE sobre el esquema auth. Es el minimo posible.
--
-- POR QUE ES SEGURO: USAGE sobre un esquema NO da acceso a sus objetos, solo permite
-- resolverlos. Para leer auth.users haria falta SELECT sobre esa tabla, que analytics_ro no
-- tiene y, siendo NOINHERIT, tampoco puede heredar de ningun rol. Igual se revoca de forma
-- explicita mas abajo y se verifica al final.
-- Idempotente.

begin;

grant usage on schema auth to analytics_ro;

-- Cinturon y tirantes: que no quede ninguna via de lectura a las tablas de auth.
revoke all privileges on all tables    in schema auth from analytics_ro;
revoke all privileges on all sequences in schema auth from analytics_ro;

commit;


-- Verificacion: debe imprimir todo en orden. Si dice PELIGRO, revertir con
--   revoke usage on schema auth from analytics_ro;
do $$
declare
  v_usage  boolean;
  v_users  boolean;
  v_ident  boolean;
begin
  v_usage := has_schema_privilege('analytics_ro', 'auth', 'USAGE');
  v_users := has_table_privilege ('analytics_ro', 'auth.users', 'SELECT');
  begin
    v_ident := has_table_privilege('analytics_ro', 'auth.identities', 'SELECT');
  exception when others then
    v_ident := false;
  end;

  raise notice 'USAGE sobre auth ............ %', v_usage;
  raise notice 'SELECT sobre auth.users ..... %  (debe ser false)', v_users;
  raise notice 'SELECT sobre auth.identities  %  (debe ser false)', v_ident;

  if v_users or v_ident then
    raise warning 'PELIGRO: analytics_ro puede leer tablas de auth. Revertir el grant.';
  else
    raise notice 'OK: analytics_ro resuelve auth.uid() pero NO puede leer datos de auth.';
  end if;
end $$;

notify pgrst, 'reload schema';
