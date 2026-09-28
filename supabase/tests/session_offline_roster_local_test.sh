#!/usr/bin/env bash
# Disposable PostgreSQL; never connects to a configured Supabase project.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55450}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mangopos-session-roster.XXXXXX")
cleanup() { "$PG/pg_ctl" -D "$WORK/data" stop -m fast >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$PG/initdb" -D "$WORK/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$WORK/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$WORK/log" start -w >/dev/null
Q() { "$PG/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U postgres "$@"; }
Q <<'SQL'
create role authenticated;
create role anon;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.user_id', true), '')::uuid;
$$;
create table public.user_businesses(user_id uuid, business_id uuid, role text);
create table public.profiles(id uuid, full_name text, email text);
create table public.employees(id uuid, user_id uuid, business_id uuid,
  first_name text, last_name text, email text, pin_hash text, status text);
create function public.fn_user_effective_permissions(p_user_id uuid, p_business_id uuid)
returns table(code text, allowed boolean) language sql as $$
  select 'ventas.acceso'::text, true where p_user_id is not null
  union all select 'ventas.borrar', false;
$$;
insert into public.user_businesses values
 ('11111111-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cashier'),
 ('22222222-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','admin');
insert into public.employees values
 ('11111111-1111-1111-1111-111111111111','11111111-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Ana','Perez',null,'hash-a','active'),
 ('22222222-2222-2222-2222-222222222222','22222222-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','Otro','Negocio',null,'hash-b','active'),
 ('33333333-3333-3333-3333-333333333333',null,'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Mesero','Sin cuenta',null,'hash-c','active'),
 ('44444444-4444-4444-4444-444444444444','44444444-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Acceso','Revocado',null,'hash-d','active');
create function public.test_check(label text, ok boolean) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS %', label;
end $$;
SQL
Q -f "$REPO/supabase/migrations/20260928_0002_session_offline_roster.sql"
Q -f "$REPO/supabase/migrations/20260928_0002_session_offline_roster.sql"
Q <<'SQL'
select public.test_check('anon has no execute privilege', not has_function_privilege('anon', 'public.fn_sync_business_roster(uuid)', 'execute'));
set role authenticated;
do $$ begin
  begin
    perform public.fn_sync_business_roster('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    raise exception 'FAIL unauthenticated download accepted';
  exception when insufficient_privilege then
    raise notice 'PASS missing session rejected';
  end;
end $$;
set test.user_id = '11111111-0000-0000-0000-000000000001';
do $$ declare payload jsonb; own_user jsonb; begin
  payload := public.fn_sync_business_roster('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  perform public.test_check('download without any device registration', jsonb_array_length(payload->'roster') = 2);
  perform public.test_check('preserves business and original timestamp', payload->>'business_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and payload->>'synced_at' is not null);
  select value into own_user from jsonb_array_elements(payload->'roster') where value->>'user_id' = '11111111-0000-0000-0000-000000000001';
  perform public.test_check('downloads hash and only granted permissions', own_user->>'pin_hash' = 'hash-a' and own_user->'permissions' = '["ventas.acceso"]'::jsonb);
  perform public.test_check('no foreign or revoked membership hashes', payload::text not like '%hash-b%' and payload::text not like '%hash-d%');
  begin
    perform public.fn_sync_business_roster('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
    raise exception 'FAIL foreign business accepted';
  exception when insufficient_privilege then
    raise notice 'PASS foreign business rejected';
  end;
end $$;
reset role;
update public.employees set status = 'inactive' where pin_hash = 'hash-a';
set role authenticated;
select public.test_check('inactive employees remain explicitly disabled',
  (select (value->>'is_active')::boolean = false
   from jsonb_array_elements(public.fn_sync_business_roster('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')->'roster')
   where value->>'pin_hash' = 'hash-a'));
reset role;
delete from public.user_businesses where user_id = '11111111-0000-0000-0000-000000000001';
set role authenticated;
do $$ begin
  begin
    perform public.fn_sync_business_roster('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    raise exception 'FAIL removed membership accepted';
  exception when insufficient_privilege then
    raise notice 'PASS removed caller membership rejected';
  end;
end $$;
SQL
printf 'PASS session roster migration on disposable PostgreSQL\n'
