-- DIAGNOSTICO_vistas_analytics.sql
-- Recorre TODAS las vistas de analytics CON EL ROL REAL DE LA API (analytics_ro) y reporta
-- cuales fallan.
--
-- OJO: correrlo como `postgres` da falsos OK. Postgres tiene privilegios que analytics_ro no
-- tiene (por ejemplo USAGE sobre el esquema auth), y varios permisos se validan contra el
-- INVOCADOR y no contra el owner de la vista. Por eso el bucle hace `set local role`.
--
-- No cambia nada permanente (tabla temporal de sesion).

create temp table if not exists _chequeo(vista text, resultado text);
truncate _chequeo;

do $$
declare
  r    record;
  n    bigint;
  res  text[] := '{}';
begin
  -- hacerse pasar por la API key
  perform set_config('request.jwt.claim.sub',
                     (select u.id::text from auth.users u
                       where u.email = 'lectura.penda@mangopos.do'), false);

  for r in select table_name from information_schema.tables
            where table_schema = 'analytics' and table_type = 'VIEW'
            order by table_name
  loop
    begin
      -- SET LOCAL es transaccional: si la consulta falla, el bloque de excepcion
      -- restaura el rol solo.
      execute 'set local role analytics_ro';
      execute format('select count(*) from analytics.%I', r.table_name) into n;
      execute 'reset role';
      res := res || (r.table_name || ' | OK ' || n || ' filas');
    exception when others then
      execute 'reset role';
      res := res || (r.table_name || ' | ERROR: ' || sqlerrm);
    end;
  end loop;

  execute 'reset role';
  insert into _chequeo
  select split_part(x, ' | ', 1), split_part(x, ' | ', 2) from unnest(res) x;
end $$;

select vista, resultado from _chequeo where resultado like 'ERROR%'
union all
select 'zzz1 ===== vistas OK =====',        count(*)::text from _chequeo where resultado like 'OK%'
union all
select 'zzz2 ===== vistas CON ERROR =====', count(*)::text from _chequeo where resultado like 'ERROR%'
order by 1;
