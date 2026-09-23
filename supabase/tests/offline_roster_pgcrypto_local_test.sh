#!/usr/bin/env bash
# PostgreSQL desechable: reproduce el error real y aplica la migración dos veces.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55449}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mangopos-roster-test.XXXXXX")
cleanup() { "$PG/pg_ctl" -D "$WORK/data" stop -m fast >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$PG/initdb" -D "$WORK/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$WORK/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$WORK/log" start -w >/dev/null
Q() { "$PG/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U postgres "$@"; }
Q <<'SQL'
create schema extensions;
create extension pgcrypto with schema extensions;
create role authenticated;
create table public.device_registrations(id uuid primary key, business_id uuid, device_token_hash text, revoked_at timestamptz, last_seen timestamptz);
create table public.user_businesses(user_id uuid, business_id uuid, role text, permissions jsonb);
create table public.profiles(id uuid, full_name text, email text);
create table public.employees(id uuid, user_id uuid, business_id uuid, first_name text, last_name text, email text, pin_hash text, status text);
insert into public.device_registrations values
 ('11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',extensions.crypt('fixture-valid-token',extensions.gen_salt('bf',4)),null,null),
 ('22222222-2222-2222-2222-222222222222','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',extensions.crypt('fixture-revoked-token',extensions.gen_salt('bf',4)),now(),null);
insert into public.user_businesses values
 ('11111111-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cashier','["ventas.acceso"]'),
 ('22222222-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','admin','[]');
insert into public.profiles values ('11111111-0000-0000-0000-000000000001','Empleado de prueba',null);
create function public.test_check(label text, ok boolean) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %', label; end if;
 raise notice 'PASS %', label;
end $$;
SQL
# Usar la función REAL original, con la configuración instalada que causa 42883.
python3 - "$REPO" "$WORK/roster-original.sql" <<'PY'
from pathlib import Path
import sys
s=(Path(sys.argv[1])/'supabase/migrations/20260522_0001_auth_offline_roster.sql').read_text()
a=s.index('create or replace function public.fn_sync_roster(')
b=s.index('grant execute on function public.fn_sync_roster(text) to authenticated;',a)+len('grant execute on function public.fn_sync_roster(text) to authenticated;')
Path(sys.argv[2]).write_text(s[a:b])
PY
Q -f "$WORK/roster-original.sql"
Q <<'SQL'
alter function public.fn_sync_roster(text) set search_path = public, pg_catalog;
revoke all on function public.fn_sync_roster(text) from public;
create table public.acl_before as select proacl::text as acl from pg_proc where oid='public.fn_sync_roster(text)'::regprocedure;
do $$ begin
 begin
  perform public.fn_sync_roster('fixture-valid-token');
  raise exception 'FAIL: se esperaba 42883';
 exception when undefined_function then
  raise notice 'PASS reproduce crypt no resuelto';
 end;
end $$;
SQL
Q -f "$REPO/supabase/migrations/20260922_0001_sync_roster_pgcrypto.sql"
Q -f "$REPO/supabase/migrations/20260922_0001_sync_roster_pgcrypto.sql"
Q <<'SQL'
-- Una función homónima en public no debe capturar la comprobación del token.
create function public.crypt(text,text) returns text language sql as $$ select 'incorrecto'::text $$;
set role authenticated;
select public.test_check('token válido y aislamiento entre negocios',
 public.fn_sync_roster('fixture-valid-token')->>'business_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
 and jsonb_array_length(public.fn_sync_roster('fixture-valid-token')->'roster')=1);
do $$ declare token text; begin
 foreach token in array array['fixture-invalid-token','fixture-revoked-token'] loop
  begin
   perform public.fn_sync_roster(token);
   raise exception 'FAIL: token aceptado indebidamente';
  exception when raise_exception then
   if sqlerrm <> 'INVALID_DEVICE_TOKEN' then raise; end if;
  end;
 end loop;
 begin
  perform public.fn_sync_roster('');
  raise exception 'FAIL: token vacío aceptado';
 exception when raise_exception then
  if sqlerrm <> 'DEVICE_TOKEN_REQUIRED' then raise; end if;
 end;
 raise notice 'PASS rechaza tokens vacíos, inválidos y revocados';
end $$;
reset role;
select public.test_check('conserva ACL y SECURITY DEFINER',
 (select p.proacl::text=b.acl and p.prosecdef from pg_proc p cross join public.acl_before b where p.oid='public.fn_sync_roster(text)'::regprocedure));
select public.test_check('conserva token y actualiza last_seen',
 (select device_token_hash=extensions.crypt('fixture-valid-token',device_token_hash) and last_seen is not null from public.device_registrations where id='11111111-1111-1111-1111-111111111111'));
SQL
printf 'PASS migración de roster validada en PostgreSQL local\n'
