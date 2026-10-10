#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261009_0006: reemplazo atómico del set, aprobaciones por emisor y
# reserva de la simulación con dos sesiones a la vez.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55452}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_ecf_test_set
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
create table public.businesses(id uuid primary key);
create table public.ecf_onboarding(business_id uuid primary key references public.businesses(id), updated_by uuid);
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok,false) then raise exception 'FAIL: %',message; end if;
  raise notice 'ok: %',message;
end $$;
insert into businesses values ('00000000-0000-0000-0000-0000000000b1');
insert into ecf_onboarding(business_id) values ('00000000-0000-0000-0000-0000000000b1');
SQL
Q -f "$M/20261008_0003_ecf_test_set.sql"
Q -f "$M/20261009_0002_ecf_test_set_approvals.sql"
Q -f "$M/20261009_0003_ecf_simulation_set.sql"
Q -f "$M/20261009_0006_ecf_test_set_atomic_replace.sql"
Q -f "$M/20261009_0006_ecf_test_set_atomic_replace.sql"

Q <<'SQL'
create function public.test_case(pos int, encf text, via text default 'ecf', issuer text default null)
returns jsonb language sql as $$
  select jsonb_build_object('position', pos, 'case_id', encf, 'ecf_type', substr(encf, 2, 2), 'encf', encf,
    'total', 100, 'via', via, 'modifies', null, 'fields', '[["eNCF","x"]]'::jsonb, 'summary_fields', null,
    'issuer_rnc', issuer)
$$;

do $$
declare
  b uuid := '00000000-0000-0000-0000-0000000000b1';
  n integer;
  failed boolean;
begin
  -- Set de e-CF inicial.
  n := fn_ecf_replace_test_set_cases(b, 'ecf', jsonb_build_array(test_case(1,'E310000000001'), test_case(2,'E310000000002')));
  perform test_assert(n = 2, 'replace inserts the new e-CF set');

  -- Un set nuevo con un e-NCF repetido no entra y el anterior queda intacto.
  failed := false;
  begin
    perform fn_ecf_replace_test_set_cases(b, 'ecf', jsonb_build_array(test_case(1,'E310000000009'), test_case(2,'E310000000009')));
  exception when unique_violation then failed := true;
  end;
  perform test_assert(failed, 'duplicate e-NCF in an e-CF set is still rejected');
  perform test_assert((select array_agg(encf order by position) from ecf_test_set_cases where business_id=b and kind='ecf')
    = array['E310000000001','E310000000002'], 'failed import keeps the previous set (atomic replace)');

  -- Aprobaciones: el mismo e-NCF de dos emisores son dos casos.
  n := fn_ecf_replace_test_set_cases(b, 'acecf', jsonb_build_array(
    test_case(1,'E310000000006','acecf','131880681'), test_case(2,'E310000000006','acecf','101555555')));
  perform test_assert(n = 2, 'same e-NCF from two issuers imports as two approvals');
  failed := false;
  begin
    perform fn_ecf_replace_test_set_cases(b, 'acecf', jsonb_build_array(
      test_case(1,'E310000000007','acecf','131880681'), test_case(2,'E310000000007','acecf','131880681')));
  exception when unique_violation then failed := true;
  end;
  perform test_assert(failed, 'same issuer and e-NCF twice is rejected');
  perform test_assert((select count(*) from ecf_test_set_cases where business_id=b and kind='acecf') = 2,
    'failed approval import keeps the previous approvals');
  perform test_assert((select count(*) from ecf_test_set_cases where business_id=b and kind='ecf') = 2,
    'loading approvals leaves the e-CF set alone');

  -- Simulación: reserva con las secuencias leídas.
  perform fn_ecf_replace_simulation_set(b, null, '{}'::jsonb, '{"31": 12}'::jsonb,
    jsonb_build_array(test_case(1,'E310000000011'), test_case(2,'E310000000012')));
  perform test_assert((select simulation_sequences from ecf_onboarding where business_id=b) = '{"31": 12}'::jsonb
    and (select simulation_set_generated_at is not null from ecf_onboarding where business_id=b),
    'simulation reserves its numbers');
  perform test_assert((select count(*) from ecf_test_set_cases where business_id=b and kind='sim') = 2,
    'simulation replaces its cases');

  -- Quien armó con secuencias viejas no reserva ni toca los casos.
  failed := false;
  begin
    perform fn_ecf_replace_simulation_set(b, null, '{}'::jsonb, '{"31": 12}'::jsonb,
      jsonb_build_array(test_case(1,'E310000000011')));
  exception when others then failed := sqlerrm = 'SIMULATION_CONFLICT';
  end;
  perform test_assert(failed, 'stale sequences abort with SIMULATION_CONFLICT');
  perform test_assert((select count(*) from ecf_test_set_cases where business_id=b and kind='sim') = 2,
    'conflict leaves the simulation cases untouched');
end $$;

do $$
declare acl text;
begin
  perform test_assert(not has_function_privilege('authenticated', 'public.fn_ecf_replace_test_set_cases(uuid,text,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.fn_ecf_replace_simulation_set(uuid,uuid,jsonb,jsonb,jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.fn_ecf_replace_simulation_set(uuid,uuid,jsonb,jsonb,jsonb)', 'execute'),
    'only service_role can replace test sets');
end $$;
SQL

# Dos «Generar» a la vez con las mismas secuencias leídas ({"31": 12}): la
# primera sesión reserva y se queda con la fila bloqueada; la segunda espera y,
# al soltarse el bloqueo, aborta en vez de reusar los mismos e-NCF.
Q -c "begin; select fn_ecf_replace_simulation_set('00000000-0000-0000-0000-0000000000b1', null,
  '{\"31\": 12}'::jsonb, '{\"31\": 14}'::jsonb,
  jsonb_build_array(test_case(1,'E310000000013'), test_case(2,'E310000000014'))); select pg_sleep(2); commit;" >/dev/null &
FIRST=$!
sleep 0.5
if Q -c "select fn_ecf_replace_simulation_set('00000000-0000-0000-0000-0000000000b1', null,
  '{\"31\": 12}'::jsonb, '{\"31\": 14}'::jsonb,
  jsonb_build_array(test_case(1,'E310000000013'), test_case(2,'E310000000014')));" >"$D/second.out" 2>&1; then
  echo "FAIL: concurrent simulation with stale sequences was accepted"; exit 1
fi
wait "$FIRST"
grep -q SIMULATION_CONFLICT "$D/second.out" || { cat "$D/second.out"; echo "FAIL: second session did not report SIMULATION_CONFLICT"; exit 1; }
Q <<'SQL'
do $$ begin
  perform test_assert((select simulation_sequences from ecf_onboarding) = '{"31": 14}'::jsonb
    and (select array_agg(encf order by position) from ecf_test_set_cases where kind='sim') = array['E310000000013','E310000000014'],
    'concurrent generate: one wins, the other aborts without reusing numbers');
end $$;
SQL

Q -c "delete from ecf_test_set_cases where kind = 'acecf';"
Q -f "$M/20261009_0006_ecf_test_set_atomic_replace_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  perform test_assert(to_regprocedure('public.fn_ecf_replace_test_set_cases(uuid,text,jsonb)') is null
    and to_regprocedure('public.fn_ecf_replace_simulation_set(uuid,uuid,jsonb,jsonb,jsonb)') is null
    and not exists (select 1 from information_schema.columns where table_name='ecf_test_set_cases' and column_name='issuer_rnc')
    and exists (select 1 from pg_constraint where conname='ecf_test_set_cases_encf_unique'),
    'rollback restores the previous schema');
end $$;
SQL
echo "ECF test set replace: OK"
