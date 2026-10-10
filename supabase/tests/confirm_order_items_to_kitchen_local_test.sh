#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0002 (fn_confirm_order_items_to_kitchen) con los cuerpos
# reales de current_user_business_ids y del disparador que impide resucitar
# órdenes cerradas (20260830_0007). consume_inventory_from_order es un doble
# que anota cada llamada.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55461}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_confirm_items
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
  zone_id uuid not null references public.zones(id));
create table public.table_sessions(id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.dining_tables(id), business_id uuid, closed_at timestamptz);
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id), status text not null default 'open',
  status_ext public.order_status not null default 'open', closed_at timestamptz);
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), status public.item_status default 'draft');
create table public.test_consumed(order_id uuid, at timestamptz default clock_timestamp());
create function public.consume_inventory_from_order(_order_id uuid) returns void language sql as $$
  insert into public.test_consumed(order_id) values (_order_id)
$$;
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
insert into businesses values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009');
insert into user_businesses values ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', false);
insert into zones(id, business_id) values ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
-- Una orden por caso con tres borradores (r1, r2 impresos; late agregado después).
create table public.test_ids(name text primary key, id uuid);
create function public.test_sale(p_prefix text, p_business_on_session boolean default true)
returns uuid language plpgsql as $$
declare t uuid; s uuid; o uuid; i uuid;
begin
  insert into dining_tables(zone_id) values ('c0000000-0000-0000-0000-000000000001') returning id into t;
  insert into table_sessions(table_id, business_id)
    values (t, case when p_business_on_session then 'b0000000-0000-0000-0000-000000000001'::uuid end)
    returning id into s;
  insert into orders(session_id) values (s) returning id into o;
  insert into order_items(order_id) values (o) returning id into i;
  insert into test_ids values (p_prefix || ':r1', i);
  insert into order_items(order_id) values (o) returning id into i;
  insert into test_ids values (p_prefix || ':r2', i);
  insert into order_items(order_id) values (o) returning id into i;
  insert into test_ids values (p_prefix || ':late', i);
  insert into test_ids values (p_prefix, o);
  return o;
end $$;
create function public.test_id(p_name text) returns uuid language sql stable as $$
  select id from public.test_ids where name = p_name
$$;
create function public.istatus(p_name text) returns text language sql stable as $$
  select status::text from public.order_items where id = public.test_id(p_name)
$$;
SQL

# Cuerpos reales del repo.
python3 - "$REPO/supabase" "$D/base.sql" <<'PY'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
def cut(rel, start, end_marker='$$;'):
    s = (root / rel).read_text()
    a = s.index(start)
    return s[a:s.index(end_marker, a) + len(end_marker)] + '\n'
resurrect = (root / 'migrations/20260830_0007_orders_no_kitchen_resurrect.sql').read_text()
a = resurrect.index('create or replace function public.fn_orders_no_kitchen_resurrect()')
b = resurrect.index('comment on function public.fn_orders_no_kitchen_resurrect()')
out.write_text(
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.current_user_business_ids()') +
    resurrect[a:b])
PY
Q -f "$D/base.sql" >/dev/null
Q -f "$M/20261010_0002_confirm_order_items_to_kitchen.sql"
Q -f "$M/20261010_0002_confirm_order_items_to_kitchen.sql"

Q <<'SQL'
do $$
declare o uuid; n int;
begin
  o := test_sale('a');
  n := fn_confirm_order_items_to_kitchen(o, array[test_id('a:r1'), test_id('a:r2')]);
  perform test_assert(n = 2 and istatus('a:r1') = 'pending' and istatus('a:r2') = 'pending',
    'the printed lines go to pending');
  perform test_assert(istatus('a:late') = 'draft',
    'a line added after the local print stays draft (it never reached the kitchen)');
  perform test_assert((select status_ext = 'sent_to_kitchen' and status = 'sent' from orders where id = o),
    'the order is marked as sent, like fn_confirm_order_to_kitchen');
  perform test_assert((select count(*) = 1 from test_consumed where order_id = o),
    'inventory consumption is recalculated once');

  n := fn_confirm_order_items_to_kitchen(o, array[test_id('a:r1'), test_id('a:r2')]);
  perform test_assert(n = 0 and (select count(*) = 1 from test_consumed where order_id = o),
    'replaying the same round is a no-op (no second consumption)');

  o := test_sale('b');
  update order_items set status = 'preparing' where id = test_id('b:r1');
  update order_items set status = 'void' where id = test_id('b:r2');
  n := fn_confirm_order_items_to_kitchen(o, array[test_id('b:r1'), test_id('b:r2')]);
  perform test_assert(n = 0 and istatus('b:r1') = 'preparing' and istatus('b:r2') = 'void'
    and (select status_ext = 'open' from orders where id = o)
    and not exists (select 1 from test_consumed where order_id = o),
    'lines no longer in draft are left alone and the order is not touched');

  o := test_sale('c');
  perform test_sale('d');
  n := fn_confirm_order_items_to_kitchen(o, array[test_id('d:r1'), test_id('c:r1')]);
  perform test_assert(n = 1 and istatus('c:r1') = 'pending' and istatus('d:r1') = 'draft',
    'ids from another order are ignored');

  o := test_sale('e');
  update orders set status_ext = 'paid', closed_at = now() where id = o;
  n := fn_confirm_order_items_to_kitchen(o, array[test_id('e:r1')]);
  perform test_assert(n = 1 and (select status_ext = 'paid' and closed_at is not null from orders where id = o),
    'a closed order is not resurrected to sent_to_kitchen (existing trigger)');

  o := test_sale('f');
  perform test_assert(fn_confirm_order_items_to_kitchen(o, array[]::uuid[]) = 0
    and fn_confirm_order_items_to_kitchen(o, null) = 0
    and istatus('f:r1') = 'draft', 'an empty list confirms nothing');
  perform test_assert(fn_confirm_order_items_to_kitchen(gen_random_uuid(), array[test_id('f:r1')]) = 0,
    'an unknown order confirms nothing');

  perform test_sale('member', false);
  perform test_sale('outsider');
end $$;
SQL

# Con JWT: alguien del negocio puede (aunque la sesión vieja no tenga business_id);
# alguien de afuera no; anon no tiene EXECUTE.
r=$(QU "$MEMBER" -t -A -c "select fn_confirm_order_items_to_kitchen(test_id('member'), array[test_id('member:r1')])")
[ "$r" = "1" ] || { echo "FAIL: member could not confirm ($r)"; exit 1; }
echo "ok: member of the business confirms (business resolved through the zone)"
if QU "$OUTSIDER" -c "select fn_confirm_order_items_to_kitchen(test_id('outsider'), array[test_id('outsider:r1')])" >"$D/out.txt" 2>&1; then
  echo "FAIL: outsider confirmed another business's lines"; exit 1
fi
grep -q NOT_A_MEMBER "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected NOT_A_MEMBER"; exit 1; }
echo "ok: outsider is rejected with NOT_A_MEMBER"
Q <<'SQL'
do $$ begin
  perform test_assert(istatus('outsider:r1') = 'draft', 'the outsider changed nothing');
  perform test_assert(not has_function_privilege('anon', 'public.fn_confirm_order_items_to_kitchen(uuid, uuid[])', 'execute')
    and has_function_privilege('authenticated', 'public.fn_confirm_order_items_to_kitchen(uuid, uuid[])', 'execute'),
    'anon cannot execute; authenticated can');
end $$;
SQL

Q -f "$M/20261010_0002_confirm_order_items_to_kitchen_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  perform test_assert(to_regprocedure('public.fn_confirm_order_items_to_kitchen(uuid, uuid[])') is null,
    'rollback removes the function');
end $$;
SQL
echo "Confirm order items to kitchen: OK"
