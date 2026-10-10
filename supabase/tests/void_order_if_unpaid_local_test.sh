#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261009_0007 (fn_void_order_if_unpaid) con los cuerpos reales de
# fn_close_order_and_table y current_user_business_ids del repo, y las dos
# carreras posibles con un cobro de otra caja.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55453}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_void_if_unpaid
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
  table_id uuid not null references public.dining_tables(id), business_id uuid, closed_at timestamptz);
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id), status text not null default 'open',
  status_ext public.order_status not null default 'open', closed_at timestamptz);
create table public.order_checks(id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id), is_closed boolean not null default false,
  closed_at timestamptz);
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), status public.item_status default 'draft');
create table public.payments(id uuid primary key default gen_random_uuid(),
  order_id uuid, amount numeric not null, status text default 'completed'
  check (status in ('pending','completed','refunded','cancelled')));
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
insert into businesses values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009');
insert into user_businesses values ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', false);
insert into zones(id, business_id) values ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
-- Una venta abierta por caso; la sesión vieja sin business_id se resuelve por la zona.
create function public.test_sale(p_business_on_session boolean default true) returns uuid language plpgsql as $$
declare t uuid; s uuid; o uuid;
begin
  insert into dining_tables(zone_id) values ('c0000000-0000-0000-0000-000000000001') returning id into t;
  insert into table_sessions(table_id, business_id)
    values (t, case when p_business_on_session then 'b0000000-0000-0000-0000-000000000001'::uuid end)
    returning id into s;
  insert into orders(session_id) values (s) returning id into o;
  insert into order_checks(order_id) values (o);
  insert into order_items(order_id, status) values (o, 'pending');
  return o;
end $$;
create table public.test_ids(name text primary key, id uuid);
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
out.write_text(
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.current_user_business_ids()') +
    cut('migrations/20260624_0001_close_checks_on_order_close.sql',
        'CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(', '$function$;'))
PY
Q -f "$D/base.sql" >/dev/null
Q -f "$M/20261009_0007_void_order_if_unpaid.sql"
Q -f "$M/20261009_0007_void_order_if_unpaid.sql"

Q <<'SQL'
do $$
declare o uuid; r text;
begin
  o := test_sale();
  r := fn_void_order_if_unpaid(o);
  perform test_assert(r = 'voided' and (select status_ext = 'void' and closed_at is not null from orders where id = o)
    and (select bool_and(is_closed) from order_checks where order_id = o)
    and (select ts.closed_at is not null from table_sessions ts join orders x on x.session_id = ts.id where x.id = o),
    'open unpaid sale is voided through fn_close_order_and_table');
  perform test_assert(fn_void_order_if_unpaid(o) = 'already_closed', 'voiding twice is a no-op');

  o := test_sale();
  update orders set status_ext = 'paid', closed_at = now() where id = o;
  perform test_assert(fn_void_order_if_unpaid(o) = 'already_closed'
    and (select status_ext = 'paid' from orders where id = o), 'a paid sale is never voided');

  o := test_sale();
  insert into payments(order_id, amount, status) values (o, 50, 'completed');
  perform test_assert(fn_void_order_if_unpaid(o) = 'has_payments'
    and (select status_ext = 'open' and closed_at is null from orders where id = o),
    'a sale with a partial payment is not voided');

  o := test_sale();
  insert into payments(order_id, amount, status) values (o, 50, 'pending');
  perform test_assert(fn_void_order_if_unpaid(o) = 'has_payments', 'a pending payment also blocks the void');

  o := test_sale();
  insert into payments(order_id, amount, status) values (o, 50, 'cancelled'), (o, 20, 'refunded');
  perform test_assert(fn_void_order_if_unpaid(o) = 'voided', 'cancelled or refunded payments do not block');

  o := test_sale();
  update orders set status_ext = 'partially_paid' where id = o;
  perform test_assert(fn_void_order_if_unpaid(o) = 'has_payments', 'partially_paid status blocks the void');

  o := test_sale();
  update order_items set status = 'paid' where order_id = o;
  perform test_assert(fn_void_order_if_unpaid(o) = 'has_payments', 'paid items (check payment) block the void');

  perform test_assert(fn_void_order_if_unpaid(gen_random_uuid()) = 'not_found', 'unknown order reports not_found');

  insert into test_ids values ('member', test_sale(false)), ('outsider', test_sale()),
    ('pay_first', test_sale()), ('void_first', test_sale());
end $$;
SQL

# Con JWT: alguien del negocio puede (aunque la sesión vieja no tenga business_id);
# alguien de afuera no; anon no tiene EXECUTE.
r=$(QU "$MEMBER" -t -A -c "select fn_void_order_if_unpaid((select id from test_ids where name='member'))")
[ "$r" = "voided" ] || { echo "FAIL: member could not void ($r)"; exit 1; }
echo "ok: member of the business voids (business resolved through the zone)"
if QU "$OUTSIDER" -c "select fn_void_order_if_unpaid((select id from test_ids where name='outsider'))" >"$D/out.txt" 2>&1; then
  echo "FAIL: outsider voided another business's sale"; exit 1
fi
grep -q NOT_A_MEMBER "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected NOT_A_MEMBER"; exit 1; }
echo "ok: outsider is rejected with NOT_A_MEMBER"
Q <<'SQL'
do $$ begin
  perform test_assert(not has_function_privilege('anon', 'public.fn_void_order_if_unpaid(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.fn_void_order_if_unpaid(uuid)', 'execute'),
    'anon cannot execute; authenticated can');
end $$;
SQL

# Carrera 1: otra caja cobra (bloquea la orden como fn_process_payment_v3) y
# tarda en confirmar; la anulación espera y, al ver el cobro, no anula.
Q -c "begin; select 1 from orders where id = (select id from test_ids where name='pay_first') for update;
  insert into payments(order_id, amount, status) select id, 100, 'completed' from test_ids where name='pay_first';
  select pg_sleep(2); commit;" >/dev/null &
PAY=$!
sleep 0.5
r=$(Q -t -A -c "select fn_void_order_if_unpaid((select id from test_ids where name='pay_first'))")
wait "$PAY"
[ "$r" = "has_payments" ] || { echo "FAIL: void ran over a concurrent payment ($r)"; exit 1; }
echo "ok: payment first: the concurrent void waits and skips the paid sale"

# Carrera 2: la anulación llega primero y se queda con la fila; el cobro, que
# rechaza órdenes anuladas como fn_process_payment_v3, ya no la ve abierta.
Q -c "begin; select fn_void_order_if_unpaid((select id from test_ids where name='void_first')); select pg_sleep(2); commit;" >/dev/null &
VOID=$!
sleep 0.5
st=$(Q -t -A -c "begin; select status_ext from orders where id = (select id from test_ids where name='void_first') for update; commit;" | head -1)
wait "$VOID"
[ "$st" = "void" ] || { echo "FAIL: payment saw the order as $st after the void"; exit 1; }
echo "ok: void first: a payment taking the row afterwards sees it voided"

Q -f "$M/20261009_0007_void_order_if_unpaid_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  perform test_assert(to_regprocedure('public.fn_void_order_if_unpaid(uuid)') is null, 'rollback removes the function');
end $$;
SQL
echo "Void order if unpaid: OK"
