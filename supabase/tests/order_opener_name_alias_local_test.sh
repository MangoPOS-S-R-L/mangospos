#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de 20261009_0005 (fn_order_opener_name: alias del access check).
# Postgres 15 DESECHABLE con el esquema mínimo; corre los archivos REALES del
# repo (migración y rollback). No toca ninguna base real.
#
#   1. El ROLLBACK (= definición viva de prod) reproduce el 42703 para la app.
#   2. La migración devuelve el mesero del PIN, no la cuenta del equipo.
#   3. Sigue negando otro negocio (42501) y service_role sigue pasando.
#
#   bash supabase/tests/order_opener_name_alias_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55449).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55449}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_order_opener_name
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }
expect() { # label, esperado, sql
  local out
  out=$(Q -c "$3" 2>&1)
  if [[ "$out" == *"$2"* ]]; then ok "$1"; else echo "    obtuvo: $out"; bad "$1"; fi
}

BIZ=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
OTHER=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
DEVICE=cccccccc-cccc-cccc-cccc-cccccccccccc     # cuenta logueada del equipo
EMP_CLAUDIA=dddddddd-dddd-dddd-dddd-dddddddddddd
EMP_DEVICE=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee
S_PIN=11111111-1111-1111-1111-111111111111
S_NOPIN=22222222-2222-2222-2222-222222222222
S_OTHER=33333333-3333-3333-3333-333333333333
O_PIN=44444444-4444-4444-4444-444444444444
O_NOPIN=55555555-5555-5555-5555-555555555555
O_OTHER=66666666-6666-6666-6666-666666666666

echo "== Esquema mínimo (current_user_business_ids SETOF uuid, como prod)"
Q <<SQL || { bad "esquema"; exit 1; }
create role authenticated; create role anon; create role service_role;
create schema auth;
create function auth.role() returns text language sql stable as \$\$
  select coalesce(current_setting('test.jwt_role', true), 'authenticated')
\$\$;
create function auth.uid() returns uuid language sql stable as \$\$
  select nullif(current_setting('test.uid', true), '')::uuid
\$\$;
create table public.user_businesses (user_id uuid, business_id uuid);
create function public.current_user_business_ids() returns setof uuid
language sql stable as \$\$
  select business_id from public.user_businesses where user_id = auth.uid()
\$\$;
create table public.profiles (id uuid primary key, full_name text);
create table public.employees (id uuid primary key, business_id uuid,
  user_id uuid, first_name text, last_name text);
create table public.table_sessions (id uuid primary key, business_id uuid,
  opened_by uuid, opened_by_employee_id uuid);
create table public.orders (id uuid primary key, session_id uuid);

insert into public.user_businesses values ('$DEVICE', '$BIZ');
insert into public.profiles values ('$DEVICE', 'Arianis Cuenta');
insert into public.employees values
  ('$EMP_CLAUDIA', '$BIZ', null, 'Claudia', 'Perez'),
  ('$EMP_DEVICE', '$BIZ', '$DEVICE', 'Arianis', 'Cuenta');
insert into public.table_sessions values
  ('$S_PIN', '$BIZ', '$DEVICE', '$EMP_CLAUDIA'),
  ('$S_NOPIN', '$BIZ', '$DEVICE', null),
  ('$S_OTHER', '$OTHER', '$DEVICE', '$EMP_CLAUDIA');
insert into public.orders values
  ('$O_PIN', '$S_PIN'), ('$O_NOPIN', '$S_NOPIN'), ('$O_OTHER', '$S_OTHER');
SQL

AS_APP="set test.uid = '$DEVICE'; set test.jwt_role = 'authenticated';"

echo "== 1. Definición viva (ROLLBACK): la app recibe 42703"
Q -f "$M/20261009_0005_order_opener_name_alias_ROLLBACK.sql" >/dev/null || bad "rollback aplica"
expect "app → 42703 (por eso caía al usuario logueado)" "c.bid does not exist" \
  "$AS_APP select public.fn_order_opener_name('$O_PIN');"
expect "service_role 'funciona' (por eso en el SQL Editor no se veía)" "Claudia Perez" \
  "set test.jwt_role = 'service_role'; select public.fn_order_opener_name('$O_PIN');"

echo "== 2. Migración: la app recibe el mesero correcto"
Q -f "$M/20261009_0005_order_opener_name_alias.sql" >/dev/null || bad "migración aplica"
Q -f "$M/20261009_0005_order_opener_name_alias.sql" >/dev/null || bad "migración idempotente"
expect "mesa con PIN → el mesero, no la cuenta del equipo" "Claudia Perez" \
  "$AS_APP select public.fn_order_opener_name('$O_PIN');"
expect "mesa sin PIN → la cuenta que la abrió (empleado)" "Arianis Cuenta" \
  "$AS_APP select public.fn_order_opener_name('$O_NOPIN');"
expect "otro negocio → 42501" "access denied" \
  "$AS_APP select public.fn_order_opener_name('$O_OTHER');"
expect "orden inexistente → null" "NULO" \
  "$AS_APP select coalesce(public.fn_order_opener_name('99999999-9999-9999-9999-999999999999'), 'NULO');"
expect "service_role sigue pasando" "Claudia Perez" \
  "set test.jwt_role = 'service_role'; select public.fn_order_opener_name('$O_OTHER');"
expect "verificación de la migración dice OK" "OK" \
  "select case when pg_get_functiondef(to_regprocedure('public.fn_order_opener_name(uuid)'))
          ~* 'current_user_business_ids\(\)\s+as\s+c\s*\(\s*business_id\s*\)'
        then 'OK' else 'NO APLICADA' end;"

echo
if [ "$FAIL" -eq 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; exit 1; fi
