#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0030 (T02): las liberaciones automáticas de mesas solo
# ocurren con la confirmación de todas las terminales participantes, sobre la
# misma versión de la sesión. Usa los cuerpos reales de current_user_business_ids
# e is_member_of_business; aplica la migración dos veces y su reversa.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55463}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_table_release_acks
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
QU() { local uid=$1; shift; PGOPTIONS="-c request.jwt.claim.sub=$uid" Q "$@"; }
MEMBER=a0000000-0000-0000-0000-000000000001
OUTSIDER=a0000000-0000-0000-0000-000000000004

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claim.sub', true), ''), '')::uuid
$$;
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create table public.businesses(id uuid primary key, owner_id uuid);
create table public.memberships(user_id uuid not null, business_id uuid not null);
create table public.user_businesses(user_id uuid not null, business_id uuid not null,
  shared_across_branches boolean not null default false);
create table public.zones(id uuid primary key default gen_random_uuid(), business_id uuid not null);
create table public.dining_tables(id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones(id), state text not null default 'occupied');
create table public.table_sessions(id uuid primary key default gen_random_uuid(),
  table_id uuid references public.dining_tables(id), business_id uuid,
  opened_at timestamptz not null default now(), closed_at timestamptz,
  origin text not null default 'quick');
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id), status text not null default 'open',
  status_ext public.order_status not null default 'open',
  created_at timestamptz not null default now(), closed_at timestamptz);
create table public.order_checks(id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id), total numeric not null default 0,
  is_closed boolean not null default false);
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), status public.item_status default 'draft');
create table public.payments(id uuid primary key default gen_random_uuid(),
  order_id uuid, amount numeric not null, status text default 'completed');
create table public.device_sessions(business_id uuid not null, device_id text not null,
  revoked_at timestamptz, unique (business_id, device_id));
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
insert into businesses values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009');
insert into user_businesses values ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', false);
insert into zones(id, business_id) values ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
-- Una mesa con su sesión y una orden vacía, abiertas hace una hora (más que la
-- gracia del barrido). Devuelve la orden.
create table public.test_ids(name text primary key, id uuid);
create function public.test_table(p_name text, p_business_on_session boolean default true)
returns uuid language plpgsql as $$
declare t uuid; s uuid; o uuid;
begin
  insert into dining_tables(zone_id) values ('c0000000-0000-0000-0000-000000000001') returning id into t;
  insert into table_sessions(table_id, business_id, opened_at)
    values (t, case when p_business_on_session then 'b0000000-0000-0000-0000-000000000001'::uuid end,
            now() - interval '1 hour')
    returning id into s;
  insert into orders(session_id, created_at) values (s, now() - interval '1 hour') returning id into o;
  insert into test_ids values (p_name, o), (p_name || ':session', s), (p_name || ':table', t);
  return o;
end $$;
create function public.tid_of(p_name text) returns uuid language sql stable as $$
  select id from public.test_ids where name = p_name
$$;
create function public.session_open(p_name text) returns boolean language sql stable as $$
  select closed_at is null from public.table_sessions where id = public.tid_of(p_name || ':session')
$$;
SQL

python3 - "$REPO/supabase" "$D/base.sql" <<'PY'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
def cut(rel, start, end_marker='$$;'):
    s = (root / rel).read_text()
    a = s.index(start)
    return s[a:s.index(end_marker, a) + len(end_marker)] + '\n'
out.write_text(
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.current_user_business_ids()') +
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.is_member_of_business(p_business uuid)'))
PY
Q -f "$D/base.sql" >/dev/null
# Como en producción: la contención y su ajuste a 30 min van antes que T02.
Q -f "$M/20261010_0004_contain_auto_releases.sql" >/dev/null
Q -f "$M/20261010_0021_sweep_dine_in_30min.sql" >/dev/null
CONTAINED=$(Q -t -A -c "select md5(prosrc) from pg_proc where proname = 'fn_release_empty_tables'")
Q -f "$M/20261010_0030_table_release_acks.sql"
Q -f "$M/20261010_0030_table_release_acks.sql"

Q <<'SQL'
create function public.version_of(p_name text) returns bigint language sql stable as $$
  select public.fn_session_version(public.tid_of(p_name || ':session'))
$$;
create function public.participate(p_name text, p_device text) returns void language sql as $$
  select public.fn_register_session_participant(public.tid_of(p_name), p_device)
$$;
create function public.ack(p_name text, p_device text, p_pending boolean default false,
  p_version bigint default null) returns jsonb language sql as $$
  select public.fn_ack_session_release(public.tid_of(p_name || ':session'), p_device,
    coalesce(p_version, public.version_of(p_name)), p_pending)
$$;
SQL

Q <<'SQL'
do $$
declare r jsonb; v bigint;
begin
  -- T1: terminal aislada con productos pendientes mientras otra barre.
  perform test_table('isolated');
  perform participate('isolated', 'tablet-A');
  perform participate('isolated', 'tablet-B');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('isolated')
    and exists (select 1 from table_session_release_requests where session_id = tid_of('isolated:session')),
    'sweep does not release: it leaves a release request');
  r := ack('isolated', 'tablet-A');
  perform test_assert(r ->> 'reason' = 'awaiting_acks' and session_open('isolated'),
    'one terminal confirming is not enough: the other has not answered');
  perform fn_release_empty_tables(20);
  perform fn_release_empty_tables(0);
  perform test_assert(session_open('isolated')
    and (select status_ext = 'open' and closed_at is null from orders where id = tid_of('isolated')),
    'the isolated terminal never answered: the account and the table are kept');
  -- Vuelve la red: su producto sube a la MISMA orden y la cuenta sigue abierta.
  insert into order_items(order_id, status) values (tid_of('isolated'), 'draft');
  perform fn_release_empty_tables(0);
  perform test_assert(session_open('isolated')
    and (select count(*) = 1 from order_items where order_id = tid_of('isolated')),
    'the isolated terminal syncs later: its product lands in the kept account');

  -- Mínimo de salón (20261010_0021): T02 conserva los 30 min.
  perform test_table('dine_in');
  update table_sessions set origin = 'dine_in', opened_at = now() - interval '25 minutes'
   where id = tid_of('dine_in:session');
  update orders set created_at = now() - interval '25 minutes' where id = tid_of('dine_in');
  perform participate('dine_in', 'tablet-A');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('dine_in')
    and not exists (select 1 from table_session_release_requests where session_id = tid_of('dine_in:session')),
    'a dine-in table younger than 30 min is not even asked for');
  update table_sessions set opened_at = now() - interval '40 minutes' where id = tid_of('dine_in:session');
  update orders set created_at = now() - interval '40 minutes' where id = tid_of('dine_in');
  perform fn_release_empty_tables(20);
  r := ack('dine_in', 'tablet-A');
  perform test_assert((r ->> 'released')::boolean and not session_open('dine_in'),
    'after 30 min a dine-in table goes through the same confirmations');

  -- T2: todas confirman sin pendientes la versión vigente → se libera.
  perform test_table('all_ack');
  perform participate('all_ack', 'tablet-A');
  perform participate('all_ack', 'tablet-B');
  perform fn_release_empty_tables(20);
  perform ack('all_ack', 'tablet-A');
  r := ack('all_ack', 'tablet-B');
  perform test_assert((r ->> 'released')::boolean and not session_open('all_ack')
    and (select status_ext = 'void' and closed_at is not null from orders where id = tid_of('all_ack'))
    and (select state = 'available' from dining_tables where id = tid_of('all_ack:table'))
    and not exists (select 1 from table_session_release_requests where session_id = tid_of('all_ack:session')),
    'the last confirmation releases in the same locked step');

  -- T3: un cambio después de las confirmaciones invalida el pedido.
  perform test_table('changed');
  perform participate('changed', 'tablet-A');
  perform fn_release_empty_tables(20);
  v := version_of('changed');
  insert into order_items(order_id, status) values (tid_of('changed'), 'void');
  r := ack('changed', 'tablet-A', false, v);
  perform test_assert(not (r ->> 'released')::boolean and session_open('changed'),
    'a confirmation of an older version does not release');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('changed')
    and (select version = version_of('changed') from table_session_release_requests
          where session_id = tid_of('changed:session')),
    'the sweep renews the request for the current version');
  r := ack('changed', 'tablet-A');
  perform test_assert((r ->> 'released')::boolean and not session_open('changed'),
    'confirmed again on the current version: released');

  -- T3b: confirmó todo y antes del barrido entró un cobro → se conserva.
  perform test_table('late_payment');
  perform participate('late_payment', 'tablet-A');
  perform participate('late_payment', 'tablet-B');
  perform fn_release_empty_tables(20);
  perform ack('late_payment', 'tablet-A');
  insert into payments(order_id, amount, status) values (tid_of('late_payment'), 10, 'pending');
  r := ack('late_payment', 'tablet-B', false, (select version from table_session_release_requests
                                              where session_id = tid_of('late_payment:session')));
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('late_payment'),
    'a payment after the confirmations changes the version: kept');

  -- T4: una terminal informa pendientes.
  perform test_table('pending');
  perform participate('pending', 'tablet-A');
  perform fn_release_empty_tables(20);
  r := ack('pending', 'tablet-A', true);
  perform fn_release_empty_tables(20);
  perform test_assert(r ->> 'reason' = 'pending_reported' and session_open('pending')
    and exists (select 1 from fn_pending_release_requests('b0000000-0000-0000-0000-000000000001', 'tablet-A')
                 where session_id = tid_of('pending:session')),
    'reported pending work keeps the session and asks again later');

  -- T5: sin participantes (versión anterior de la app) no se puede comprobar.
  perform test_table('legacy');
  perform fn_release_empty_tables(0);
  perform fn_release_empty_tables(0);
  perform test_assert(session_open('legacy'),
    'no registered terminals: the sweep cannot prove it empty and keeps it');

  -- T6: un equipo cerrado a distancia ya no retiene.
  perform test_table('retired');
  perform participate('retired', 'tablet-A');
  perform participate('retired', 'tablet-lost');
  insert into device_sessions values ('b0000000-0000-0000-0000-000000000001', 'tablet-lost', now());
  perform fn_release_empty_tables(20);
  r := ack('retired', 'tablet-A');
  perform test_assert((r ->> 'released')::boolean, 'a revoked device does not hold the session');

  -- T7: salir de una mesa vacía con la app nueva.
  perform test_table('leave_alone');
  r := fn_release_empty_table_v2(tid_of('leave_alone'), 'tablet-A', false);
  perform test_assert((r ->> 'released')::boolean and not session_open('leave_alone'),
    'the only participant leaving an empty table releases it at once');
  perform test_table('leave_shared');
  perform participate('leave_shared', 'tablet-B');
  r := fn_release_empty_table_v2(tid_of('leave_shared'), 'tablet-A', false);
  perform test_assert(r ->> 'reason' = 'awaiting_acks' and session_open('leave_shared'),
    'another participant must confirm first');
  perform test_assert((select order_ids = array[tid_of('leave_shared')]
                         from fn_pending_release_requests('b0000000-0000-0000-0000-000000000001', 'tablet-B')
                        where session_id = tid_of('leave_shared:session')),
    'the other terminal is asked, with the order ids it must check');
  r := ack('leave_shared', 'tablet-B');
  perform test_assert((r ->> 'released')::boolean and not session_open('leave_shared')
    and (select status_ext = 'void' from orders where id = tid_of('leave_shared')),
    'its confirmation releases the left table');
  perform test_table('leave_pending');
  r := fn_release_empty_table_v2(tid_of('leave_pending'), 'tablet-A', true);
  perform test_assert(r ->> 'reason' = 'pending_reported' and session_open('leave_pending'),
    'the leaving terminal itself has pending work: kept');
  perform test_table('leave_items');
  insert into order_items(order_id, status) values (tid_of('leave_items'), 'draft');
  r := fn_release_empty_table_v2(tid_of('leave_items'), 'tablet-A', false);
  perform test_assert(r ->> 'reason' = 'order_has_items', 'an order with items is never released');

  -- T8: lo que no es participante no confirma.
  perform test_table('stranger');
  perform participate('stranger', 'tablet-A');
  perform fn_release_empty_tables(20);
  r := ack('stranger', 'tablet-Z');
  perform test_assert(r ->> 'reason' = 'not_participant' and session_open('stranger'),
    'a terminal that never took part cannot confirm');

  perform test_table('member_check', false);
  perform test_table('outsider_check');
end $$;
SQL

# Con JWT: alguien del negocio puede (sesión vieja sin business_id: por la zona);
# alguien de afuera no; anon no tiene EXECUTE.
QU "$MEMBER" -c "select fn_register_session_participant(tid_of('member_check'), 'tablet-M')" >/dev/null
r=$(QU "$MEMBER" -t -A -c "select fn_release_empty_table_v2(tid_of('member_check'), 'tablet-M', false) ->> 'released'")
[ "$r" = "true" ] || { echo "FAIL: member could not release ($r)"; exit 1; }
echo "ok: member of the business registers and releases (business resolved through the zone)"
r=$(QU "$MEMBER" -t -A -c "select fn_release_empty_table(tid_of('legacy')) ->> 'reason'")
[ "$r" = "no_participants" ] || { echo "FAIL: old leave call released a legacy table ($r)"; exit 1; }
echo "ok: the old app's leave call does not release a table no terminal can vouch for"
for call in \
  "select fn_register_session_participant(tid_of('outsider_check'), 'tablet-X')" \
  "select fn_release_empty_table_v2(tid_of('outsider_check'), 'tablet-X', false)" \
  "select * from fn_pending_release_requests('b0000000-0000-0000-0000-000000000001', 'tablet-X')"; do
  if QU "$OUTSIDER" -c "$call" >"$D/out.txt" 2>&1; then
    echo "FAIL: outsider ran: $call"; exit 1
  fi
  grep -q NOT_A_MEMBER "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected NOT_A_MEMBER"; exit 1; }
done
echo "ok: outsiders are rejected with NOT_A_MEMBER"
Q <<'SQL'
do $$ begin
  perform test_assert(session_open('outsider_check'), 'the outsider changed nothing');
  perform test_assert(
    not has_function_privilege('anon', 'public.fn_release_empty_table_v2(uuid, text, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.fn_ack_session_release(uuid, text, bigint, boolean)', 'execute')
    and has_function_privilege('authenticated', 'public.fn_ack_session_release(uuid, text, bigint, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'public.fn_fulfill_session_release_locked(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.fn_bump_session_version(uuid)', 'execute'),
    'only the terminal RPCs are executable; the internals are not');
end $$;
SQL

# Carrera: un producto entra mientras el barrido tiene tomada la mesa; al
# soltarla, la confirmación ya no vale para la versión nueva.
Q <<'SQL'
do $$ begin
  perform test_table('race');
  perform participate('race', 'tablet-A');
  perform fn_release_empty_tables(20);
end $$;
SQL
Q -c "begin; select pg_advisory_xact_lock(hashtextextended(tid_of('race:table')::text, 0));
  insert into order_items(order_id, status) values (tid_of('race'), 'draft'); select pg_sleep(2); commit;" >/dev/null &
ADD=$!
sleep 0.5
r=$(Q -t -A -c "select ack('race', 'tablet-A', false, (select version from table_session_release_requests where session_id = tid_of('race:session'))) ->> 'reason'")
wait "$ADD"
[ "$r" = "changed_after_request" ] || { echo "FAIL: release ran over a concurrent add ($r)"; exit 1; }
echo "ok: a product added while the table is locked wins over the pending release"

Q -f "$M/20261010_0030_table_release_acks_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  perform test_assert(to_regclass('public.table_session_release_requests') is null
    and to_regprocedure('public.fn_release_empty_table_v2(uuid, text, boolean)') is null
    and to_regprocedure('public.fn_release_empty_tables(integer, uuid)') is not null
    and to_regprocedure('public.fn_release_empty_table(uuid)') is not null,
    'rollback removes the protocol and restores the previous release functions');
  perform test_table('after_rollback');
  perform fn_release_empty_tables(20);
  perform test_assert(not session_open('after_rollback'), 'the restored sweep releases as before');
end $$;
SQL
r=$(Q -t -A -c "select md5(prosrc) from pg_proc where proname = 'fn_release_empty_tables'")
[ "$r" = "$CONTAINED" ] || { echo "FAIL: rollback did not restore the live (contained) sweep"; exit 1; }
echo "ok: rollback restores exactly the live sweep (20261010_0021, 30 min for dine-in)"
r=$(Q -t -A -c "select pg_get_functiondef('public.fn_release_empty_table(uuid)'::regprocedure) like '%pg_advisory_xact_lock(hashtextextended(v_table_id::text, 0))%'")
[ "$r" = "t" ] || { echo "FAIL: rollback lost the table lock of 20261010_0023 on exit release"; exit 1; }
echo "ok: rollback restores the exit release of 20261010_0023 (row + advisory lock)"
echo "Table release acks: OK"
